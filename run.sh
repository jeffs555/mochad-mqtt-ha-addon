#!/usr/bin/with-contenv bashio

declare host
declare password
declare port
declare username



    host=$(bashio::services "mqtt" "host")
    password=$(bashio::services "mqtt" "password")
    port=$(bashio::services "mqtt" "port")
    username=$(bashio::services "mqtt" "username")


#cat /data/options.json
cp -f /data/options.json /mochad-mqtt.json
sed -i -n '/{/{N/"name":/D}p' /mochad-mqtt.json
sed -i '/"name":/{s/,/:{/}' /mochad-mqtt.json
sed -i 's/"name"://' /mochad-mqtt.json
sed -i 's/\[//' /mochad-mqtt.json
sed -i 's/],//' /mochad-mqtt.json
sed -i 's/]//' /mochad-mqtt.json
sed -i 's/"devices":/"devices": {/' /mochad-mqtt.json
sed -i 's/"mqtt":/},\n   "mqtt":/' /mochad-mqtt.json
sed -i 's/"mochad":/,\n   "mochad":/' /mochad-mqtt.json
sed -i 's/"hass":/,\n   "hass":/' /mochad-mqtt.json
sed -i -n '/"log_level"/{d}p' /mochad-mqtt.json
#cat /mochad-mqtt.json


sed -i "s/\"host\": \"xxxxxxxx\"/\"host\": \"$host\"/" /mochad-mqtt.json
sed -i "s/\"user\": \"xxxxxxxx\"/\"user\": \"$username\"/" /mochad-mqtt.json
sed -i "s/\"password\": \"xxxxxxxx\"/\"password\": \"$password\"/" /mochad-mqtt.json
sed -i "s/\"port\": \"xxxxxxxx\"/\"port\": \"$port\"/" /mochad-mqtt.json


cat /mochad-mqtt.json

perl /mochad-mqtt.pl

