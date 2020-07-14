-module(discord_gateway).
-behaviour(gen_server).

-export([start_link/1, heartbeat/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

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
    gen_server:start_link(?MODULE, [Token], []).

-spec heartbeat(pid()) -> ok.
heartbeat(Pid) ->
    gen_server:cast(Pid, heartbeat),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% gen_server callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init([Token]) ->
    gen_server:cast(self(), connect),
    {ok, #state{token=Token}}.

handle_call(_Message, _From, State) ->
    {noreply, State}.

handle_cast(connect, State) ->
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
            {noreply,
             State#state{url=Gateway,
                         connection=#connection{pid=ConnPid, ref=MRef},
                         log=Log}};
        {gun_response, ConnPid, _StreamRef, _Fin, _Status, _Headers} ->
            {stop, ws_upgrade_failed, State};
        {gun_error, ConnPid, _StreamRef, Reason} ->
            logger:error("gun error: ~p~n", [Reason]),
            {stop, ws_upgrade_failed, State}
    after 1000 -> {stop, timeout}
    end;
handle_cast(heartbeat, S=#state{connection=#connection{pid=Pid},
                                sequence=Seq}) ->
    logger:info("sending heartbeat"),
    send_message(Pid, 1, Seq),
    {noreply, S};
handle_cast(identify, S=#state{connection=#connection{pid=Pid}, token=Token}) ->
    logger:info("sending identify"),
    send_message(Pid, 2, #{<<"token">> => Token,
                           <<"properties">> => #{
                               <<"$os">> => <<"beam">>,
                               <<"$browser">> => ?LIBRARY_NAME,
                               <<"$device">> => ?LIBRARY_NAME
                              }
                          }),
    {noreply, S}.

handle_info({gun_ws, ConnPid, _StreamRef, {text, Msg}},
            S=#state{connection=#connection{pid=ConnPid}, log=Log}) ->
    Json = jsone:decode(Msg),
    logger:debug("message recevied: ~p", [Json]),
    ok = file:write(Log, [Msg, "\n"]),
    NewState = handle_ws_message(Json, S),
    {noreply, NewState}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% helper functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

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
    discord_gateway:heartbeat(self()),
    State#state{heartbeat=Ref};
handle_ws_message_(11, _Msg, State) ->
    logger:info("received heartbeat ack"),
    % TODO make sure we receive an ack between heartbeats
    case State#state.session_id of
        undefined -> gen_server:cast(self(), identify);
        _ -> ok
    end,
    State.

send_message(ConnPid, OpCode, Msg) ->
    gun:ws_send(ConnPid,
                {text, jsone:encode(#{<<"op">> => OpCode, <<"d">> => Msg})}).
