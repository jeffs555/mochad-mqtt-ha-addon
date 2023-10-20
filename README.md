# mochad-mqtt-ha

Mochad-mqtt-ha-addon provides an alternative to the X10 integration built into Home Assistant. Added features are the ability to receive inputs from X10 remote controls and motion detectors, and use them as triggers in automations to control other devices. In addition to controlling X10 powerline devices, it also allows control directly to and from X10 RF devices. It provides a bridge between the Mosquitto MQTT addon and the [Mochad](https://github.com/FloridaMan7588/mochad-ha-addon) addon. It allows X10 devices to appear to Home Assistant as MQTT devices. It is basically just the Perl script from [mochad-mqtt](https://github.com/timothyh/mochad-mqtt) with a few changes, and the necessary files to make it install as a Home Assistant addon.

I did this just for my own use, but decided to publish it on [Github](https://github.com/jeffs555/mochad-mqtt-ha-addon) just in case anyone else is still using some X10 devices. I had been running mochad-mqtt on a separate linux machine and added provisions for X10 RF devices to the mochad-mqtt perl script. It was working very well, but I wanted to run it on the same Raspberry Pi running Home Assistant Operating System. Never written a HA addon before so not sure I did things the right way. It works for me, but your mileage may vary. Does not currently support X10 Security Devices or X10 cameras as I don't have any.


## Prerequisites

To install this addon, you will need to install the Mosquitto MQTT broker in the HA add-ons menu from the add-ons store. You will also need the Mochad add-on from FloridaMan7588. It is not in the add-on store,and has to be added to the repository. He has detailed instructions [here](https://github.com/floridaman7588/mochad-ha-addon). The Mochad addon uses an X10 CM15A, CM15Pro, or CM19A as a controller. You also need to add the MQTT integration in the HA devices menu.



## Installation

In HA, you go to SETTINGS, ADD-ONS, ADD-ON Store. Then from the 3 dots at the top right, select repositories and add the repository https://github.com/jeffs555/mochad-mqtt-ha-addon. Then from the 3 dot menu, check for updates and mochad-mqtt-ha-addon should appear in the store, and you can click it to install.



## Configuration

All configuration is done from the configuration tab in the mochad-mqtt-ha addon. 

You need to configure any X10 devices you want to control. For each X10 device you need enter parameters as follows:

- name: AnyName

  code: A12
  
  type: switch

Name can be anything you want, but must be at least 4 character long. 
For powerline devices, code is the housecode + unit number for the X10 device. For RF devices, code is  housecode + 99 + unit number. Note that 99 is just a prefix to the unit number, not added numerically.
Options for type are switch, light, sensor, remote. State is saved for switch, light, and sensor so only triggers when state changes. Remotes trigger every time on or off are pressed. 
You can copy and paste the configuration to save it or edit it elsewhere.

For using X10 remotes and sensors as triggers in automations select MQTT as the trigger.
Then enter  home/x10/devicename/state  for the topic. For devicename use the name configured in mochad-mqtt-ha configuration. For devices that you have not configured, the name will be housecode + unit number for powerline devices, and housecode + 99 + unit number for RF devices.
For payload enter ON or OFF .

For the other configuration items such as host, port, username, password the defaults should work and should not need to be changed. 

