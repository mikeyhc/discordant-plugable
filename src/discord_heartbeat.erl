-module(discord_heartbeat).

-export([create_heartbeat/2]).

create_heartbeat(Interval, Pid) ->
    {ok, TRef} = timer:apply_interval(Interval, discord_gateway, heartbeat,
                                      [Pid]),
    TRef.
