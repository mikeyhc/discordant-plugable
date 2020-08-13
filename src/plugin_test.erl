-module(plugin_test).

-export([main/1]).

main(Name) ->
    {ok, Socket} = chumak:socket(req, Name),
    case chumak:connect(Socket, tcp, "localhost", 5554) of
        {ok, _Pid} ->
            send_messages(Socket, [
                                   <<"Hello my dear friend">>,
                                   <<"Hello my old friend">>,
                                   <<"Hello all the things">>
                                  ]);
        {error, Reason} ->
            io:format("Connection Failed for this reason: ~p\n", [Reason]);
        Reply ->
            io:format("Unhandled reply for connect ~p \n", [Reply])
    end.

send_messages(Socket, []) ->
    send_messages(Socket, [
                           <<"Hello my dear friend">>,
                           <<"Hello my old friend">>,
                           <<"Hello all the things">>
                          ]);

send_messages(Socket, [Message|Messages]) ->
    case chumak:send(Socket, Message) of
        ok ->
            io:format("~p Send message: ~p\n", [self(), Message]);
        {error, Reason} ->
            io:format("~p Failed to send message: ~p, reason: ~p\n", [self(), Message, Reason])
    end,
    case chumak:recv(Socket) of
        {ok, RecvMessage} ->
            io:format("~p Recv message: ~p\n", [self(), RecvMessage]);
        {error, RecvReason} ->
            io:format("~p Failed to recv, reason: ~p\n", [self(), RecvReason])
    end,
    timer:sleep(1000),
    send_messages(Socket, Messages).
