Bacon = require 'baconjs'
http = require('http')
net = require('net')
carrier = require('carrier')
ads = require('ads')
async = require('async')



houmioBridge = process.env.HOUMIO_BRIDGE || "localhost:3001"
bridgeDaliSocket = new net.Socket()
bridgeDmxSocket = new net.Socket()
bridgeAcSocket = new net.Socket()


houmioBeckhoffIp = process.env.HOUMIO_BECKHOFF_IP || "192.168.1.104"
houmioAmsSourceId = process.env.HOUMIO_BECKHOFF_AMS_SOURCE_ID || "192.168.1.103.1.1"
houmioAmsTargetId = process.env.HOUMIO_BECKHOFF_AMS_TARGET_ID || "5.21.69.109.1.1"

console.log "Using HOUMIO_BECKHOFF_IP=#{houmioBeckhoffIp}"
console.log "Using HOUMIO_BECKHOFF_AMS_SOURCE_ID=#{houmioAmsSourceId}"
console.log "Using HOUMIO_BECKHOFF_AMS_TARGET_ID=#{houmioAmsTargetId}"

adsClient = null

#ADS Messages

sendAcMessageToAds = (message) ->
  #console.log "AC Message", message
  if message.data.type is 'binary'
    if message.data.on is true then onOff = 1 else onOff = 0
    dataHandle = {
      symname: ".HMI_RelayControls[#{message.data.protocolAddress}]",
      bytelength: ads.BYTE,
      value: onOff
    }
    try
      adsClient.write dataHandle, (err) ->
        if err then console.log "AC Relay Write Error", err
    catch error
      console.log "General AC Relay Write Error", error
  else
    dataHandle = {
      symname: ".HMI_DimmerControls[#{message.data.protocolAddress}]"
      bytelength: ads.INT,
      value: message.data.bri
    }
    try
      adsClient.write dataHandle, (err) ->
        if err then console.log "AC Relay Write Error", err
    catch error
      console.log "General AC Relay Write Error", error


sendDaliMessageToAds = (message) ->
  if message.data.bri is 255 then message.data.bri = 254

  dataHandle = {
    symname: ".HMI_LightControls[#{message.data.protocolAddress}]",
    bytelength: 2,
    propname: 'value',
    value: new Buffer [0x01, message.data.bri]
  }

  try
    adsClient.write dataHandle, (err) ->
      if err then console.log "Dali Write Error", err
  catch error
    console.log "General Dali Write Error", error


hslToRgbw = (hue, saturation, lightness) ->

  if saturation is 0 then return [0, 0, 0, lightness]
  hueToRgb = (p, q, t) ->
    if t < 0 then t += 1
    if t > 1 then t -= 1
    if t < 1/6 then return p + (q - p) * 6 * t
    if t < 1/2 then return q
    if t < 2/3 then return p + (q - p) * (2/3 - t) * 6
    return p
  lightness /= 255
  saturation /= 255
  hue /= 255
  q = if lightness < 0.5 then lightness * (1 + saturation) else lightness + saturation - lightness * saturation
  p = 2 * lightness - q
  r = hueToRgb p, q, hue + 1/3
  g = hueToRgb p, q, hue
  b = hueToRgb p, q, hue - 1/3
  [Math.round(r * 255), Math.round(g * 255), Math.round(b * 255), Math.round(lightness / saturation)]





dmxToAds = (address, value, dmxToAdsCb) ->
  dataHandle = {
    symname: ".HMI_DMXPROCDATA[#{address}]",
    bytelength: ads.BYTE,
    propname: 'value',
    value: value
  }
  console.log dataHandle.symname
  if adsClient
    adsClient.write dataHandle, (err) ->
      dmxToAdsCb err

sendDmxMessageToAds = (message) ->
  console.log "DMX", message
  if message.data.type is 'color'
    rgbw = hslToRgbw message.data.hue, 128, message.data.bri
    console.log "RGBW", rgbw
    index = 0
    async.eachSeries rgbw, (val, cb) ->
      dmxToAds message.data.protocolAddress++, val, cb
    , (err) ->
      if err then console.log "Dmx Write error", err
  else
    dmxToAds message.data.protocolAddress++, message.data.bri, (err) ->
      if err then console.log "Dmx Write error", err

#Socket IO

isWriteMessage = (message) -> message.command is "write"

bridgeMessagesToAds = (bridgeStream, sendMessageToAds) ->
  bridgeStream
    .filter isWriteMessage
    .bufferingThrottle 10
    .onValue (message) ->
      sendMessageToAds message
      console.log "<-- Data To ADS:", message

toLines = (socket) ->
  Bacon.fromBinder (sink) ->
    carrier.carry socket, sink
    socket.on "close", -> sink new Bacon.End()
    socket.on "error", (err) -> sink new Bacon.Error(err)
    ( -> )


openBridgeMessageStream = (socket) -> (cb) ->
  socket.connect houmioBridge.split(":")[1], houmioBridge.split(":")[0], ->
    lineStream = toLines socket
    messageStream = lineStream.map JSON.parse
    cb null, messageStream

openStreams = [ openBridgeMessageStream(bridgeDaliSocket), openBridgeMessageStream(bridgeDmxSocket), openBridgeMessageStream(bridgeAcSocket)]

#openStreams = [ openBridgeMessageStream(bridgeDmxSocket) ]
async.series openStreams, (err, [bridgeDaliStream, bridgeDmxStream, bridgeAcStream]) ->
  if err then exit err
  bridgeDaliStream.onEnd -> exit "Bridge Dali stream ended"
  bridgeDmxStream.onEnd -> exit "Bridge DMX stream ended"
  bridgeAcStream.onEnd -> exit "Bridge AC stream ended"
  bridgeDaliStream.onError (err) -> exit "Error from bridge Dali stream:", err
  bridgeDmxStream.onError (err) -> exit "Error from bridge DMX stream:", errß
  bridgeAcStream.onError (err) -> exit "Error from bridge AC stream:", err
  bridgeMessagesToAds bridgeDaliStream, sendDaliMessageToAds
  bridgeMessagesToAds bridgeDmxStream, sendDmxMessageToAds
  bridgeMessagesToAds bridgeAcStream, sendAcMessageToAds
  #bridgeMessagesToSerial bridgeStream, enoceanSerial
  #enoceanMessagesToSocket enoceanStream, bridgeSocket
  bridgeDaliSocket.write (JSON.stringify { command: "driverReady", protocol: "beckhoff/dali"}) + "\n"
  bridgeDmxSocket.write (JSON.stringify { command: "driverReady", protocol: "beckhoff/dmx"}) + "\n"
  bridgeAcSocket.write (JSON.stringify { command: "driverReady", protocol: "beckhoff/ac"}) + "\n"


#Beckhoff AMS connection

beckhoffOptions = {
  #The IP or hostname of the target machine
  host: houmioBeckhoffIp,
  #The NetId of the target machine
  amsNetIdTarget: houmioAmsTargetId,
  #amsNetIdTarget: "5.21.69.109.3.4",
  #The NetId of the source machine.
  #You can choose anything in the form of x.x.x.x.x.x,
  #but on the target machine this must be added as a route.
  amsNetIdSource: houmioAmsSourceId,
  amsPortTarget: 801
  #amsPortTarget: 27906
  #amsPortTarget: 300
}

adsClient = ads.connect beckhoffOptions, ->
  console.log "Connected to Beckhoff ADS server"

  #this.getSymbols (err, result) ->
  #  console.log "ERROR: ", err
  #  console.log "symbols", result

adsClient.on 'error', (err) ->
  console.log "ADS ERROR", err
  process.exit 1