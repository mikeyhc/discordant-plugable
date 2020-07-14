-module(discord_heartbeat).

-export([create_heartbeat/2, remove_heartbeat/1]).

create_heartbeat(Interval, Pid) ->
    {ok, TRef} = timer:apply_interval(Interval, discord_gateway, heartbeat,
                                      [Pid]),
    TRef.

remove_heartbeat(Ref) ->
    {ok, cancel} = timer:cancel(Ref),
    ok.
