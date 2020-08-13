-module(plugin_server).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(REP_PORT, 5554).
-define(PUBLISH_PORT, 5555).
-define(INTERFACE, "localhost").

-record(state, {publisher :: pid() | undefined,
                pair :: pid() | undefined,
                pair_ref :: reference() | undefined
               }).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% API functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec start_link() -> any().
start_link() ->
    gen_server:start_link(?MODULE, [], []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% gen_server callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init([]) ->
    gen_server:cast(self(), start_publisher),
    gen_server:cast(self(), start_pair),
    {ok, #state{}}.

handle_call(_Msg, _From, State) ->
    {noreply, State}.

handle_cast(start_publisher, State) ->
    {ok, Socket} = bind(pub, ?PUBLISH_PORT),
    {noreply, State#state{publisher=Socket}};
handle_cast(start_pair, State) ->
    {ok, Socket} = bind(rep, ?REP_PORT),
    Self = self(),
    Pid = spawn(fun() -> pair_to_cast(Self, Socket) end),
    MRef = monitor(process, Pid),
    {noreply, State#state{pair=Socket, pair_ref=MRef}}.

handle_info({'DOWN', Ref, process, _Pid, _Reason},
            State=#state{pair_ref=Ref}) ->
    gen_server:cast(self(), start_pair),
    {noreply, State#state{pair=undefined, pair_ref=undefined}}.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% helper functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

bind(Type, Port) ->
    {ok, Socket} = chumak:socket(Type),
    case chumak:bind(Socket, tcp, ?INTERFACE, Port) of
        {ok, _BindPid} ->
            logger:info("Binding OK with Pid: ~p\n", [Socket]),
            {ok, Socket};
        E = {error, Reason} ->
            logger:error("Connection Failed for this reason: ~p\n", [Reason]),
            E
    end.

pair_to_cast(Pid, Socket) ->
    {ok, Data} = chumak:recv(Socket),
    logger:info("got msg: ~p", [Data]),
    ok = chumak:send(Socket, <<"HELO">>),
    pair_to_cast(Pid, Socket).
