-module(discord_gateway).
-behaviour(gen_statem).

-export([start_link/1, heartbeat/1]).
-export([callback_mode/0, init/1]).
-export([await_connect/3, await_hello/3, await_dispatch/3, connected/3,
         await_ack/3, disconnected/3, await_reconnect/3, await_close/3]).

-define(LIBRARY_NAME, <<"discordant">>).

-record(connection, { pid :: pid(),
                      ref :: reference()
                    }).
-record(state, { url :: string() | undefined,
                 token :: string(),
                 connection :: #connection{} | undefined,
                 heartbeat :: timer:tref() | undefined,
                 sequence :: integer() | undefined,
                 session_id :: binary() | undefined,
                 log :: file:io_device() | undefined
               }).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% API functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec start_link(string()) -> any().
start_link(Token) ->
    gen_statem:start_link(?MODULE, [Token], []).

-spec heartbeat(pid()) -> ok.
heartbeat(Pid) ->
    gen_statem:cast(Pid, heartbeat),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% gen_statem callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init([Token]) ->
    gen_statem:cast(self(), connect),
    {ok, await_connect, #state{token=Token}}.

callback_mode() ->
    state_functions.

await_connect(cast, connect, State) ->
    connect(await_hello, State).

await_hello(info, {gun_ws, ConnPid, _StreamRef, {text, Msg}},
            S=#state{connection=#connection{pid=ConnPid}, token=Token}) ->
    Json = decode_msg(Msg, S),
    case Json of
        #{<<"op">> := 10} ->
            logger:info("sending identify"),
            send_message(ConnPid, 2, #{<<"token">> => Token,
                                       <<"properties">> => #{
                                           <<"$os">> => <<"beam">>,
                                           <<"$browser">> => ?LIBRARY_NAME,
                                           <<"$device">> => ?LIBRARY_NAME
                                          }
                                      }),
            {next_state, await_dispatch, handle_ws_message(Json, S)};
        true ->
            {stop, msg_before_hello, S}
    end.

await_dispatch(info, {gun_ws, ConnPid, _StreamRef, {text, Msg}},
               S=#state{connection=#connection{pid=ConnPid}}) ->
    Json = decode_msg(Msg, S),
    case Json of
        #{<<"op">> := 0} ->
            logger:info("connected to discord"),
            {next_state, connected, handle_ws_message(Json, S)};
        #{<<"op">> := 9} ->
            logger:info("session invalidated, doing full connect"),
            demonitor(S#state.connection#connection.ref),
            gun:shutdown(ConnPid),
            gen_statem:cast(self(), connect),
            {next_state, await_close, #state{token=S#state.token}}
    end;
await_dispatch(info, {gun_ws, ConnPid, _StreamRef, {text, _Msg}}, S) ->
    logger:info("dropping message for likely stale connection ~p", [ConnPid]),
    {keep_state, S}.

await_close(info, {gun_ws, _ConnPid, _StreamRef, {close, _, _}}, State) ->
    {next_state, await_connect, State};
await_close(_, _, State) ->
    {keep_state, State, [postpone]}.

connected(cast, heartbeat,
          S=#state{connection=#connection{pid=Pid}, sequence=Seq}) ->
    logger:info("sending heartbeat"),
    send_message(Pid, 1, Seq),
    {next_state, await_ack, S};
connected(info, {gun_ws, ConnPid, _StreamRef, {text, Msg}},
          S=#state{connection=#connection{pid=ConnPid}, log=Log}) ->
    Json = jsone:decode(Msg),
    logger:debug("message recevied: ~p", [Json]),
    ok = file:write(Log, [Msg, "\n"]),
    case Json of
        #{<<"op">> := 7} ->
            {next_state, disconnected, handle_ws_message(Json, S)};
        _ -> {keep_state, handle_ws_message(Json, S)}
    end;
connected(info, {gun_down, ConnPid, _, _, _},
          S=#state{connection=#connection{pid=ConnPid}}) ->
    logger:info("gun connection lost"),
    gun:await_up(ConnPid),
    logger:info("gun connection regained"),
    gun:ws_upgrade(ConnPid, "/"),
    logger:info("upgrading connection to websocket"),
    receive
        {gun_upgrade, ConnPid, _StreamRef, [<<"websocket">>], _Headers} ->
            {keep_state, S};
        {gun_response, ConnPid, _StreamRef, _Fin, _Status, _Headers} ->
            {stop, ws_upgrade_failed, S};
        {gun_error, ConnPid, _StreamRef, Reason} ->
            logger:error("gun error: ~p~n", [Reason]),
            {stop, ws_upgrade_failed, S}
    after 2000 -> {stop, timeout}
    end;
connected(info, {gun_ws, ConnPid, _, {close, _, _}},
          S=#state{connection=#connection{pid=ConnPid}}) ->
    logger:info("websocket closed"),
    {next_state, disconnected, S#state{connection=undefined}};
connected(info, {gun_ws, ConnPid, _, {close, _, _}}, S) ->
    logger:info("ignoring likely stale message for ~p", [ConnPid]),
    {keep_state, S}.

await_ack(info, {gun_ws, ConnPid, _StreamRef, {text, Msg}},
          S=#state{connection=#connection{pid=ConnPid}}) ->
    Json = decode_msg(Msg, S),
    case Json of
        #{<<"op">> := 11} ->
            {next_state, connected, handle_ws_message(Json, S)};
        _ -> {keep_state, S, [postpone]}
    end;
await_ack(info, {gun_ws, ConnPid, _, {close, _, _}},
          S=#state{connection=#connection{pid=ConnPid}}) ->
    logger:info("websocket closed"),
    {next_state, disconnected, S#state{connection=undefined}};
await_ack(cast, heartbeat, State) ->
    logger:info("received heartbeat while awaiting ack, disconnecting"),
    gen_statem:cast(self(), reconnect),
    {next_state, disconnected, State#state{connection=undefined}}.

disconnected(cast, reconnect, State) ->
    logger:info("disconnected"),
    connect(await_reconnect, State);
disconnected(_, _, State) ->
    {keep_state, State, [postpone]}.

await_reconnect(info, {gun_ws, _ConnPid, _StreamRef, {close, _, _}}, State) ->
    {keep_state, State};
await_reconnect(info, {gun_ws, ConnPid, _StreamRef, {text, Msg}},
                S=#state{connection=#connection{pid=ConnPid},
                         token=Token,
                         session_id=SessionId,
                         sequence=Seq}) ->
    Json = decode_msg(Msg, S),
    case Json of
        #{<<"op">> := 10} ->
            logger:info("sending resume"),
            send_message(ConnPid, 6, #{<<"token">> => Token,
                                       <<"session_id">> => SessionId,
                                       <<"seq">> => Seq
                                      }),
            {next_state, await_dispatch, handle_ws_message(Json, S)};
        _ -> {stop, msg_before_hello, S}
    end;
await_reconnect(_, _, State) ->
    {keep_state, State, [postpone]}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% helper functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

decode_msg(Msg, #state{log=Log}) ->
    Json = jsone:decode(Msg),
    logger:debug("message recevied: ~p", [Json]),
    ok = file:write(Log, [Msg, "\n"]),
    Json.

handle_ws_message(Msg=#{<<"op">> := Op, <<"s">> := Seq}, State) ->
    handle_ws_message_(Op, Msg, State#state{sequence=Seq}).

handle_ws_message_(0, #{<<"d">> := Msg}, State) ->
    % TODO actually do things
    % TODO compare session ids
    % TODO ensure we only use a single session ID
    case maps:get(<<"session_id">>, Msg, undefined) of
        undefined -> State;
        SessionId -> State#state{session_id=SessionId}
    end;
handle_ws_message_(7, _Msg, State) ->
    demonitor(State#state.connection#connection.ref),
    ok = gun:shutdown(State#state.connection#connection.pid),
    gen_statem:cast(self(), reconnect),
    State#state{connection=undefined};
handle_ws_message_(10, #{<<"d">> := #{<<"heartbeat_interval">> := IV}},
                   State) ->
    if State#state.heartbeat =:= undefined -> ok;
       true -> discord_heartbeat:remove_heartbeat(State#state.heartbeat)
    end,
    Ref = discord_heartbeat:create_heartbeat(IV, self()),
    State#state{heartbeat=Ref};
handle_ws_message_(11, _Msg, State) ->
    logger:info("received heartbeat ack"),
    State.

send_message(ConnPid, OpCode, Msg) ->
    gun:ws_send(ConnPid,
                {text, jsone:encode(#{<<"op">> => OpCode, <<"d">> => Msg})}).

connect(Next, State) ->
    ApiServer = discordant_sup:get_api_server(),
    BinGateway = discord_api:get_gateway(ApiServer),
    "wss://" ++ Gateway = binary:bin_to_list(BinGateway),
    logger:info("connecting to discord gateway"),
    {ok, ConnPid} = gun:open(Gateway, 443, #{protocols => [http]}),
    {ok, _Protocol} = gun:await_up(ConnPid),
    MRef = monitor(process, ConnPid),
    gun:ws_upgrade(ConnPid, "/"),
    logger:info("connected to discord with pid ~p~n", [ConnPid]),
    receive
        {gun_upgrade, ConnPid, _StreamRef, [<<"websocket">>], _Headers} ->
            {ok, Log} = file:open("events.log", [append, {encoding, unicode}]),
            {next_state, Next,
             State#state{url=Gateway,
                         connection=#connection{pid=ConnPid, ref=MRef},
                         log=Log}};
        {gun_response, ConnPid, _StreamRef, _Fin, _Status, _Headers} ->
            {stop, ws_upgrade_failed, State};
        {gun_error, ConnPid, _StreamRef, Reason} ->
            logger:error("gun error: ~p~n", [Reason]),
            {stop, ws_upgrade_failed, State}
    after 2000 -> {stop, timeout}
    end.
