-module(discord_usermap).

-export([new/0, add_user/3, id_to_user/2, user_to_id/2]).
-export_type([usermap/0]).

-record(usermap, {id_to_user :: maps:map(string(), string()),
                  user_to_id :: maps:map(string(), string())
                 }).
-opaque usermap() :: #usermap{}.

-spec new() -> usermap().
new() ->
    #usermap{id_to_user=#{}, user_to_id=#{}}.

-spec add_user(usermap(), string(), string()) -> usermap().
add_user(#usermap{id_to_user=IdUser, user_to_id=UserId}, User, Id) ->
    #usermap{id_to_user=IdUser#{Id => User},
             user_to_id=UserId#{User => Id}}.

-spec id_to_user(usermap(), string()) -> string().
id_to_user(#usermap{id_to_user=IdUser}, Id) ->
    maps:get(Id, IdUser, false).

-spec user_to_id(usermap(), string()) -> string().
user_to_id(#usermap{user_to_id=UserId}, User) ->
    maps:get(User, UserId, false).
