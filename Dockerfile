ARG BUILD_FROM
FROM $BUILD_FROM

RUN apk add --update --no-cache wget bash perl perl-anyevent make perl-app-cpanminus perl-sub-name
RUN cpanm AnyEvent::MQTT

# Copy data for add-on
COPY mochad-mqtt.pl /mochad-mqtt.pl
COPY run.sh /run.sh
RUN chmod +x /run.sh
RUN mkdir /cache
RUN echo "{}" > /cache/states.json

CMD [ "/run.sh" ]
