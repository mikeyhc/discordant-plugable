FROM erlang:alpine

COPY _build/default/rel/discordant /discordant
ENTRYPOINT ["/discordant/bin/discordant"]
CMD ["foreground"]
