{ Decoder } = require './decoder'
ctx = require 'axel'
fs = require 'fs'

debug =
  mode: false
  maxOps: 10
  maxDataBytes: 30


iPixel = 0
draw =
  console: (color, meta) =>
    iPixel++
    colorCode = ("0#{part.toString(16)}".slice(-2) for part in color).join ''
    console.log '%c ',"background: \##{colorCode}"
  cli: (color, meta) =>
    ctx.clear() unless iPixel
    ctx.bg color[0], color[1], color[2]
    ctx.point(
      iPixel % meta.width,
      Math.floor(iPixel/meta.width) + 1
    )
    iPixel++
  debug: (color, meta) =>

fileContents = fs.readFileSync './qoi_test_images/testcard.qoi', 'binary'
decoder = Decoder fileContents, draw.cli, debug
console.log "metadata = ", decoder.meta if debug.mode
decoder.decode()

# buffer iterator. because I'm lazy and want to test with the eye
if debug.mode
  bufIter = decoder.getBufIter fileContents
  bytesWritten = 0
  bytes = []

  loop
    byte = bufIter.next()
    bytes.push decoder.valToBitMask byte.value, 8
    break if byte.done

  console.log "#{(bytes.slice 0, 14).join ' '} \nHEADER DONE\n\n#{(bytes.slice 14, debug.maxDataBytes+14).join ' '}"
