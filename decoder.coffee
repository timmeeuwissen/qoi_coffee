{ Buffer } = require 'buffer'

QWORD = 64
DWORD = 32
WORD  = 16
BYTE  =  8
SEXTET=  6
NYBBLE=  4
CRUMB =  2
BIT   =  1

instructions =
  QOI_NO_OP       : [0x00, BYTE]
  QOI_EOF         : [0x01, BYTE]
  QOI_OP_RGB      : [0xfe, BYTE, BYTE, BYTE, BYTE]
  QOI_OP_RGBA     : [0xff, BYTE, BYTE, BYTE, BYTE, BYTE]
  QOI_OP_INDEX    : [0b00, CRUMB, SEXTET]
  QOI_OP_DIFF     : [0b01, CRUMB, CRUMB, CRUMB, CRUMB]
  QOI_OP_LUMA     : [0b10, CRUMB, SEXTET, NYBBLE, NYBBLE]
  QOI_OP_RUN      : [0b11, CRUMB, SEXTET]

header = [
  {name: 'format', type: 'string', cmp: 'qoif', bytesize: 4}
  {name: 'width', type: 'bigint', bytesize: 4}
  {name: 'height', type: 'bigint', bytesize: 4}
  {name: 'channels', bytesize: 1}
  {name: 'colorspace', bytesize: 1}
]

indexRegister = (new Uint8Array [0,0,0,255] for n in [0...QWORD-1])

valToBitMask = (val, size) =>
  "0000000#{val.toString(2)}".slice(-size)

# debug purposes
opCodeToName = {}
opCodeToName[valToBitMask val[0], val[1]] = key for key, val of instructions

index =
  set: (color) =>
    [r, g, b, a] = color
    throw new Error "Mismatch in color definition" if color.length < 4
    indexRegister[(r * 3 + g * 5 + b * 7 + a * 11) % QWORD] = color
  get: (position) =>
    indexRegister[position]

getMeta = (bufIter) =>
  meta = {}
  for metaProperty in header
    data = (bufIter.next().value for n in [0...metaProperty.bytesize])
    switch metaProperty.type
      when 'string'
        val = (String.fromCharCode char for char in data).join ''
        if metaProperty.cmp && val != metaProperty.cmp
          throw new Error "Header comparison failed, got #{val} from #{data}, expected #{metaProperty.cmp}"
        meta[metaProperty.name] = val
      when 'bigint'
        val = 0
        val += byte << (BYTE * (metaProperty.bytesize - n - 1)) for byte, n in data
        meta[metaProperty.name] = val
      else
        meta[metaProperty.name] = data
  meta

getBufIter = (fileContents) =>
  fileBuffer = new Buffer fileContents, 'binary'

  bufGen = ->
    yield bufByte for bufByte in fileBuffer

  bufIter = bufGen()
  bufIter

decoder = (fileContents, draw, debug) =>
  prev = new Uint8Array [0, 0, 0, 255]

  bufIter = getBufIter fileContents

  meta = getMeta bufIter
  pixelsToSpend = meta.width * meta.height


  runner = (bufIter, chain) =>
    processedOps = 0
    loop
      opByte = bufIter.next()
      opConsumption = 8
      return if opByte.done
      for link in chain
        [[opDef, opSize, opArgSizes...], opFunc] = link
        continue unless opByte.value >> (BYTE - opSize) == opDef
        opArgs = new Uint8Array opArgSizes.length
        bitsPassed = opSize
        if opArgSizes
          for argSize, argIndex in opArgSizes
            if bitsPassed % BYTE == 0
              opByte = bufIter.next()
              opConsumption += BYTE
              bitsPassed = 0
            opArgs[argIndex] = opByte.value << bitsPassed
            opArgs[argIndex] = opArgs[argIndex] >> (BYTE - argSize)
            bitsPassed += argSize
        outcome = opFunc.call {}, opArgs...

        if debug.mode && (!debug.maxOps || processedOps < debug.maxOps)
          console.log "OP #{opCodeToName[valToBitMask opDef, opSize]} (#{valToBitMask opDef, opSize})",
            "consumed #{opConsumption} bits and executed with ",
            (valToBitMask argVal, opArgSizes[iArg] for argVal, iArg in opArgs),
            'Outcome was', outcome

        processedOps++
        break

  decide = (newValue) =>
    throw new Error "Already spent all pixels" unless pixelsToSpend
    throw new Error "Mismatch in color definition", newValue if newValue.length < 4
    color = new Uint8Array newValue
    prev = color
    index.set color
    draw color, meta unless debug.mode
    pixelsToSpend--
    color

  chain =
    [
      # QOI_NO_OP       : [0x00, BYTE]
      [instructions.QOI_NO_OP, () => {}],
      # QOI_EOF         : [0x01, BYTE]
      [instructions.QOI_EOF, () => {}],
      # QOI_OP_RGB      : [0xfe, BYTE, BYTE, BYTE, BYTE]
      [instructions.QOI_OP_RGB, (red, green, blue) =>
        decide [
          red
          green
          blue
          255
        ]
      ],
      # QOI_OP_RGBA     : [0xff, BYTE, BYTE, BYTE, BYTE, BYTE]
      [instructions.QOI_OP_RGBA, (red, green, blue, alpha) =>
        decide [
          red
          green
          blue
          alpha
        ]
      ],
      # QOI_OP_INDEX    : [0b00, CRUMB, SEXTET]
      [instructions.QOI_OP_INDEX, (indexId) =>
        decide [...index.get(indexId)]
      ],
      # QOI_OP_DIFF     : [0b01, CRUMB, CRUMB, CRUMB, CRUMB]
      [instructions.QOI_OP_DIFF, (diffRed, diffGreen, diffBlue) =>
        decide [
          prev[0] + (diffRed - 2)
          prev[1] + (diffGreen - 2)
          prev[2] + (diffBlue - 2)
          prev[3]
        ]
      ],
      # QOI_OP_LUMA     : [0b10, CRUMB, SEXTET, NYBBLE, NYBBLE]
      [instructions.QOI_OP_LUMA, (diffGreen, diffRed, diffBlue) =>
        decide [
          prev[0] + (diffRed - 8) + (diffGreen - 32)
          prev[1] + (diffGreen - 32)
          prev[2] + (diffBlue - 8) + (diffGreen - 32)
          prev[3]
        ]
      ],
      # QOI_OP_RUN      : [0b11, CRUMB, SEXTET]
      [instructions.QOI_OP_RUN, (count) =>
        decide [...prev] for [0..count]
      ],
    ]
  decode = () =>
    runner bufIter, chain
    console.log "Have #{pixelsToSpend} pixels to spend left" if debug.mode

  { meta, decode, getBufIter, valToBitMask }

module.exports = { Decoder: decoder }
