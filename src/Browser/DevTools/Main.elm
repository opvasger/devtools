module Browser.DevTools.Main exposing
    ( Model
    , Msg
    , toDocument
    , toHtml
    , toInit
    , toSubscriptions
    , toUpdate
    , toUrlMsg
    )

import Browser
import File exposing (File)
import File.Download
import File.Select
import Help
import History exposing (History)
import History.DecodeStrategy as DecodeStrategy exposing (DecodeStrategy)
import Html exposing (Html)
import Icon exposing (Icon)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Range
import Task
import TextArea
import Throttle
import Time
import Window


type Msg model msg
    = DoNothing
    | UpdateApp MsgSrc msg
    | ResetApp
    | ReplayApp Int
    | ToggleAppReplay
    | ToggleDecodeStrategy
    | ToggleModelVisibility
    | DownloadSession Time.Posix
    | DownloadSessionWithDate
    | SelectSession
    | DecodeSession File
    | SessionDecoded (Result Decode.Error (Model model msg))
    | UpdateCacheThrottle
    | InputTitle String
    | InputDescription String
    | WindowMsg Window.Msg
    | RangeMsg Range.Msg
    | FocusIcon (Maybe Icon)


type alias Model model msg =
    { history : History model msg
    , initCmd : Cmd msg
    , isModelVisible : Bool
    , decodeStrategy : DecodeStrategy
    , decodeError : Maybe ( SessionSrc, Decode.Error )
    , cacheThrottle : Throttle.Model
    , title : String
    , description : String
    , window : Window.Model
    , range : Range.Model
    , focus : Maybe Icon
    }


toUrlMsg : msg -> Msg model msg
toUrlMsg =
    UpdateApp Url


toInit :
    { init : ( model, Cmd msg )
    , msgDecoder : Decoder msg
    , update : msg -> model -> ( model, Cmd msg )
    , fromCache : Maybe String
    }
    -> ( Model model msg, Cmd (Msg model msg) )
toInit config =
    let
        decodeStrategy =
            config.fromCache
                |> Maybe.map (Decode.decodeString (Decode.field "decodeStrategy" DecodeStrategy.decoder))
                |> Maybe.map (Result.withDefault DecodeStrategy.NoErrors)
                |> Maybe.withDefault DecodeStrategy.NoErrors

        decodeSession =
            config.init
                |> sessionDecoder (Help.updateModel config.update)
                    config.msgDecoder
                    decodeStrategy

        toModel decodeError =
            { history = History.init (Tuple.first config.init)
            , initCmd = Tuple.second config.init
            , decodeError = Maybe.map (Tuple.pair Cache) decodeError
            , decodeStrategy = DecodeStrategy.UntilError
            , isModelVisible = False
            , cacheThrottle = Throttle.init
            , description = ""
            , title = defaultTitle
            , window = Tuple.first Window.init
            , range = Range.init
            , focus = Nothing
            }
    in
    config.fromCache
        |> Maybe.map ((\m -> ( m, Cmd.map WindowMsg (Tuple.second Window.init) )) << Help.unwrapResult (toModel << Just) << Decode.decodeString decodeSession)
        |> Maybe.withDefault
            ( toModel Nothing
            , Cmd.batch
                [ Cmd.map (UpdateApp Init) (Tuple.second config.init)
                , Cmd.map WindowMsg (Tuple.second Window.init)
                ]
            )


toSubscriptions :
    { msgDecoder : Decoder msg
    , subscriptions : model -> Sub msg
    , update : msg -> model -> ( model, Cmd msg )
    }
    -> Model model msg
    -> Sub (Msg model msg)
toSubscriptions config model =
    Sub.batch
        [ Sub.map WindowMsg (Window.subscriptions model.window)
        , Sub.map RangeMsg (Range.subscriptions model.range)
        , if History.isReplay model.history then
            Sub.none

          else
            Sub.map (UpdateApp Subs) (config.subscriptions (History.currentModel model.history))
        ]


toUpdate :
    { msgDecoder : Decoder msg
    , encodeMsg : msg -> Encode.Value
    , update : msg -> model -> ( model, Cmd msg )
    , toCache : String -> Cmd (Msg model msg)
    }
    -> Msg model msg
    -> Model model msg
    -> ( Model model msg, Cmd (Msg model msg) )
toUpdate config msg model =
    case msg of
        DoNothing ->
            Help.withoutCmd model

        UpdateApp src appMsg ->
            History.currentModel model.history
                |> config.update appMsg
                |> Tuple.second
                |> Cmd.map (UpdateApp Update)
                |> Tuple.pair { model | history = recordFromSrc src (Help.updateModel config.update) appMsg model.history }
                |> emitCacheSession config.toCache config.encodeMsg

        ResetApp ->
            Cmd.map (UpdateApp Init) model.initCmd
                |> Tuple.pair { model | history = History.reset model.history }
                |> emitCacheSession config.toCache config.encodeMsg

        ReplayApp index ->
            { model | history = History.replay (Help.updateModel config.update) index model.history }
                |> Help.withoutCmd
                |> emitCacheSession config.toCache config.encodeMsg

        ToggleAppReplay ->
            { model | history = History.toggleReplay (Help.updateModel config.update) model.history }
                |> Help.withoutCmd
                |> emitCacheSession config.toCache config.encodeMsg

        DownloadSessionWithDate ->
            ( model, Task.perform DownloadSession Time.now )

        DownloadSession time ->
            let
                filename =
                    Help.replaceEmptyWith defaultTitle model.title
                        ++ "."
                        ++ Help.printUtcTime time
                        ++ ".json"
            in
            encodeSession config.encodeMsg model
                |> File.Download.string filename "application/json"
                |> Tuple.pair model

        SelectSession ->
            if model.decodeError /= Nothing then
                Help.withoutCmd
                    { model | decodeError = Nothing }

            else
                DecodeSession
                    |> File.Select.file [ "application/json" ]
                    |> Tuple.pair model

        DecodeSession file ->
            let
                decodeSession =
                    model.initCmd
                        |> Tuple.pair (History.initialModel model.history)
                        |> sessionDecoder (Help.updateModel config.update) config.msgDecoder DecodeStrategy.NoErrors
            in
            File.toString file
                |> Task.map (Decode.decodeString decodeSession)
                |> Task.andThen Help.resultToTask
                |> Task.attempt SessionDecoded
                |> Tuple.pair model

        SessionDecoded result ->
            case result of
                Ok sessionModel ->
                    Help.withoutCmd sessionModel
                        |> emitCacheSession config.toCache config.encodeMsg

                Err error ->
                    Help.withoutCmd { model | decodeError = Just ( Upload, error ) }

        ToggleDecodeStrategy ->
            { model | decodeStrategy = DecodeStrategy.loop model.decodeStrategy }
                |> Help.withoutCmd
                |> emitCacheSession config.toCache config.encodeMsg

        ToggleModelVisibility ->
            { model | isModelVisible = not model.isModelVisible }
                |> Help.withoutCmd
                |> emitCacheSession config.toCache config.encodeMsg

        UpdateCacheThrottle ->
            Throttle.update (config.toCache << encodeSession config.encodeMsg)
                UpdateCacheThrottle
                model.cacheThrottle
                model
                |> Tuple.mapFirst (\cacheThrottle -> { model | cacheThrottle = cacheThrottle })

        InputTitle text ->
            { model | title = text }
                |> Help.withoutCmd
                |> emitCacheSession config.toCache config.encodeMsg

        InputDescription text ->
            { model | description = text }
                |> Help.withoutCmd
                |> emitCacheSession config.toCache config.encodeMsg

        WindowMsg windowMsg ->
            { model | window = Window.update windowMsg model.window }
                |> Help.withoutCmd
                |> emitCacheSession config.toCache config.encodeMsg

        RangeMsg rangeMsg ->
            { model | range = Range.update rangeMsg model.range }
                |> Help.withoutCmd
                |> emitCacheSession config.toCache config.encodeMsg

        FocusIcon maybeIcon ->
            ( { model | focus = maybeIcon }, Cmd.none )


toDocument :
    { encodeMsg : msg -> Encode.Value
    , encodeModel : model -> Encode.Value
    , view : model -> Browser.Document msg
    , update : msg -> model -> ( model, Cmd msg )
    }
    -> Model model msg
    -> Browser.Document (Msg model msg)
toDocument config model =
    History.currentModel model.history
        |> config.view
        |> (\{ title, body } ->
                { title = title
                , body = view config model body
                }
           )


toHtml :
    { encodeMsg : msg -> Encode.Value
    , encodeModel : model -> Encode.Value
    , view : model -> Html msg
    , update : msg -> model -> ( model, Cmd msg )
    }
    -> Model model msg
    -> Html (Msg model msg)
toHtml config model =
    config.view (History.currentModel model.history)
        |> List.singleton
        |> view config model
        |> Html.div []


view :
    { config
        | encodeMsg : msg -> Encode.Value
        , encodeModel : model -> Encode.Value
        , update : msg -> model -> ( model, Cmd msg )
    }
    -> Model model msg
    -> List (Html msg)
    -> List (Html (Msg model msg))
view config model body =
    Window.view WindowMsg
        { controls =
            [ Icon.viewJson
                { focus = model.focus
                , onFocus = FocusIcon
                , onClick = ToggleModelVisibility
                , title = "toggle model"
                , isModelVisible = model.isModelVisible
                }
            , Icon.viewUpload
                { focus = model.focus
                , onFocus = FocusIcon
                , onClick = SelectSession
                , title =
                    model.decodeError
                        |> Maybe.map printDecodeError
                        |> Maybe.withDefault "load session"
                , isFailed = model.decodeError /= Nothing
                }
            , Icon.viewDownload
                { focus = model.focus
                , onFocus = FocusIcon
                , onClick = DownloadSessionWithDate
                , title = "save session"
                }
            ]
        , body =
            [ TextArea.view
                { value = model.description
                , onInput = InputDescription
                , placeholder = "describe what you're doing here!"
                }
            ]
        , navigation =
            [ Icon.viewReplay
                { focus = model.focus
                , onFocus = FocusIcon
                , onClick = ResetApp
                , title = "restart"
                }
            , Html.map RangeMsg (Range.view model.range)
            , Icon.viewPlay
                { focus = model.focus
                , onFocus = FocusIcon
                , onClick = ToggleAppReplay
                , title = "continue"
                , isPlay = not (History.isReplay model.history)
                }
            ]
        }
        model.window
        :: List.map (Html.map (UpdateApp View)) body



-- Session


type SessionSrc
    = Cache
    | Upload


printDecodeError : ( SessionSrc, Decode.Error ) -> String
printDecodeError ( src, err ) =
    case src of
        Cache ->
            Decode.errorToString err

        Upload ->
            Decode.errorToString err


defaultTitle : String
defaultTitle =
    "devtools-session"


emitCacheSession :
    (String -> Cmd (Msg model msg))
    -> (msg -> Encode.Value)
    -> ( Model model msg, Cmd (Msg model msg) )
    -> ( Model model msg, Cmd (Msg model msg) )
emitCacheSession toCache encodeMsg ( model, cmd ) =
    Throttle.emit (toCache << encodeSession encodeMsg)
        UpdateCacheThrottle
        model.cacheThrottle
        model
        |> Tuple.mapBoth
            (\throttle -> { model | cacheThrottle = throttle })
            (\cacheCmd -> Cmd.batch [ cacheCmd, cmd ])


encodeSession : (msg -> Encode.Value) -> Model model msg -> String
encodeSession encodeMsg model =
    Encode.encode 0 <|
        Encode.object
            [ ( "history", History.encode encodeMsg model.history )
            , ( "isModelVisible", Encode.bool model.isModelVisible )
            , ( "decodeStrategy", DecodeStrategy.encode model.decodeStrategy )
            , ( "title", Encode.string model.title )
            , ( "window", Window.encode model.window )
            , ( "range", Range.encode model.range )
            , ( "description", Encode.string model.description )
            ]


sessionDecoder :
    (msg -> model -> model)
    -> Decoder msg
    -> DecodeStrategy
    -> ( model, Cmd msg )
    -> Decoder (Model model msg)
sessionDecoder update msgDecoder strategy ( model, cmd ) =
    Decode.map7
        (\history decodeStrategy isModelVisible title window description range ->
            { history = history
            , initCmd = cmd
            , decodeError = Nothing
            , decodeStrategy = decodeStrategy
            , isModelVisible = isModelVisible
            , cacheThrottle = Throttle.init
            , title = title
            , description = description
            , window = window
            , range = range
            , focus = Nothing
            }
        )
        (Decode.field "history" (DecodeStrategy.toHistoryDecoder strategy update msgDecoder model))
        (Decode.field "decodeStrategy" DecodeStrategy.decoder)
        (Decode.field "isModelVisible" Decode.bool)
        (Decode.field "title" Decode.string)
        (Decode.field "window" Window.decoder)
        (Decode.field "description" Decode.string)
        (Decode.field "range" Range.decoder)



-- MsgSrc


type MsgSrc
    = Init
    | Update
    | Subs
    | View
    | Url


recordFromSrc :
    MsgSrc
    -> (msg -> model -> model)
    -> msg
    -> History model msg
    -> History model msg
recordFromSrc src =
    case src of
        Init ->
            History.recordForever

        _ ->
            History.record
