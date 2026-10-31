# frozen_string_literal: true

require 'ffi'

module Isureal
  module JPEG
    Image = Data.define(:width, :height)

    module TurboJPEG
      extend FFI::Library

      ffi_lib ['libturbojpeg.so.0', 'turbojpeg']

      PF_RGB = 0
      PF_CMYK = 11
      CS_CMYK = 3
      CS_YCCK = 4
      FLAG_STOPONWARNING = 8192

      attach_function :tjInitDecompress, [], :pointer
      attach_function :tjDecompressHeader3, %i[pointer pointer ulong pointer pointer pointer pointer], :int
      attach_function :tjDecompress2, %i[pointer pointer ulong pointer int int int int int], :int, blocking: true
      attach_function :tjDestroy, [:pointer], :int
    end

    module_function

    def decode(data)
      handle = TurboJPEG.tjInitDecompress
      return nil if handle.null?

      jpeg = FFI::MemoryPointer.new(:uint8, data.bytesize)
      jpeg.put_bytes(0, data)
      header = FFI::MemoryPointer.new(:int, 4)
      return nil unless TurboJPEG.tjDecompressHeader3(handle, jpeg, data.bytesize, header, header + 4, header + 8, header + 12).zero?

      width, height, _subsampling, colorspace = header.read_array_of_int(4)
      cmyk = [TurboJPEG::CS_CMYK, TurboJPEG::CS_YCCK].include?(colorspace)
      # 1/8 に縮小して展開する。エントロピー復号は全量行うので壊れたデータの検出は変わらず、IDCT と画素バッファだけ小さくなる。
      scaled_width = (width + 7) / 8
      scaled_height = (height + 7) / 8
      pixels = FFI::MemoryPointer.new(:uint8, scaled_width * scaled_height * (cmyk ? 4 : 3), false)
      status = TurboJPEG.tjDecompress2(handle, jpeg, data.bytesize, pixels, scaled_width, 0, scaled_height,
                                       cmyk ? TurboJPEG::PF_CMYK : TurboJPEG::PF_RGB, TurboJPEG::FLAG_STOPONWARNING)
      status.zero? ? Image.new(width:, height:) : nil
    ensure
      pixels&.free
      jpeg&.free
      TurboJPEG.tjDestroy(handle) if handle && !handle.null?
    end
  end
end
