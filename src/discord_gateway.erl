-module(discord_gateway).
-behaviour(gen_statem).

-export([start_link/1, heartbeat/1]).
-export([callback_mode/0, init/1]).
-export([await_connect/3, await_hello/3, await_dispatch/3, connected/3,
         await_ack/3]).

-define(LIBRARY_NAME, <<"discordant">>).

-record(connection, { pid :: pid(),
                      ref :: reference()
                    }).
-record(state, { url :: string() | undefined,
                 token :: string(),
                 connection :: #connection{} | undefined,
                 heartbeat :: reference() | undefined,
                 sequence :: integer() | undefined,
                 session_id :: binary() | undefined,
                 log :: file:io_device()
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
    ApiServer = discordant_sup:get_api_server(),
    BinGateway = discord_api:get_gateway(ApiServer),
    "wss://" ++ Gateway = binary:bin_to_list(BinGateway),
    logger:info("connecting to discord gateway"),
    {ok, ConnPid} = gun:open(Gateway, 443, #{protocols => [http]}),
    {ok, _Protocol} = gun:await_up(ConnPid),
    MRef = monitor(process, ConnPid),
    gun:ws_upgrade(ConnPid, "/"),
    receive
        {gun_upgrade, ConnPid, _StreamRef, [<<"websocket">>], _Headers} ->
            {ok, Log} = file:open("events.log", [append, {encoding, unicode}]),
            {next_state, await_hello,
             State#state{url=Gateway,
                         connection=#connection{pid=ConnPid, ref=MRef},
                         log=Log}};
        {gun_response, ConnPid, _StreamRef, _Fin, _Status, _Headers} ->
            {stop, ws_upgrade_failed, State};
        {gun_error, ConnPid, _StreamRef, Reason} ->
            logger:error("gun error: ~p~n", [Reason]),
            {stop, ws_upgrade_failed, State}
    after 1000 -> {stop, timeout}
    end.

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
            {next_state, connected, handle_ws_message(Json, S)};
        true ->
            {stop, msg_before_dispatch, S}
    end.

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
    NewState = handle_ws_message(Json, S),
    {keep_state, NewState}.

await_ack(info, {gun_ws, ConnPid, _StreamRef, {text, Msg}},
          S=#state{connection=#connection{pid=ConnPid}}) ->
    Json = decode_msg(Msg, S),
    case Json of
        #{<<"op">> := 11} ->
            {next_state, connected, handle_ws_message(Json, S)};
        true ->
            {stop, msg_before_ack, S}
    end.


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

handle_ws_message_(0, #{<<"d">> := #{<<"session_id">> := SessionId}}, State) ->
    % TODO actually do things
    % TODO compare session ids
    State#state{session_id=SessionId};
handle_ws_message_(0, _Msg, State) ->
    % TODO delete this case
    State;
handle_ws_message_(10, #{<<"d">> := #{<<"heartbeat_interval">> := IV}},
                   State) ->
    if State#state.heartbeat =:= undefined -> ok;
       true -> discord_heartbeat:remove_heartbeat(State#state.heartbeat)
    end,
    Ref = discord_heartbeat:create_heartbeat(IV, self()),
    State#state{heartbeat=Ref};
handle_ws_message_(11, _Msg, State) ->
    logger:info("received heartbeat ack"),
    % TODO make sure we receive an ack between heartbeats
    State.

send_message(ConnPid, OpCode, Msg) ->
    gun:ws_send(ConnPid,
                {text, jsone:encode(#{<<"op">> => OpCode, <<"d">> => Msg})}).
