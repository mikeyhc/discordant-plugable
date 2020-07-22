-module(discord_heartbeat).

-export([create_heartbeat/2, remove_heartbeat/1]).

-spec create_heartbeat(integer(), pid()) -> timer:tref().
create_heartbeat(Interval, Pid) ->
    {ok, TRef} = timer:apply_interval(Interval, discord_gateway, heartbeat,
                                      [Pid]),
    TRef.

-spec remove_heartbeat(timer:tref()) -> ok.
remove_heartbeat(Ref) ->
    {ok, cancel} = timer:cancel(Ref),
    ok.
