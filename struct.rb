class Struct
  # The generic body of Struct#initialize.
  #
  # Struct#initialize dispatches each call to an ISEQ chosen from the call
  # shape (see struct.c). This one takes the calls whose shape does not
  # decide the result: splats, calls without a call site (send,
  # Method#call, C functions), and the error cases.
  def initialize(*args, **kw)
    Primitive.attr! :use_block
    Primitive.cstmt! %{
      rb_struct_modify(self);
      return Qnil;
    }
    n = Primitive.cexpr! 'LONG2FIX(RSTRUCT_LEN_RAW(self))'
    keyword_init = Primitive.cexpr! 'rb_struct_s_keyword_init(rb_obj_class(self))'
    argc = kw.empty? ? args.size : args.size + 1

    hash = nil
    if keyword_init.nil?
      hash = kw if argc == 1 && !kw.empty?
    elsif keyword_init
      if argc == 1
        hash = kw.empty? ? args[0] : kw
        hash = nil unless Primitive.cexpr!('RBOOL(RB_TYPE_P(hash, T_HASH))')
      end
      if argc > 0 && hash.nil?
        raise ArgumentError, "wrong number of arguments (given #{argc}, expected 0)"
      end
    end

    if hash
      i = 0
      while i < n
        Primitive.struct_set_raw(i, nil)
        i += 1
      end
      unknown = nil
      # No block: Primitive does not work inside one.
      keys = hash.keys
      j = 0
      while j < keys.size
        key = keys[j]
        val = hash[key]
        j += 1
        if Primitive.struct_symbol_p(key)
          pos = Primitive.struct_member_index(key)
        elsif Primitive.struct_string_p(key)
          sym = Primitive.struct_check_symbol(key)
          pos = sym && Primitive.struct_member_index(sym)
        else
          # Same conversion as Struct#[]: Integer, or anything NUM2LEN takes.
          key = Primitive.struct_num2len(key)
          pos = key < 0 ? key + n : key
          pos = nil if pos < 0 || n <= pos
        end
        if pos
          Primitive.struct_set_raw(pos, val)
        else
          (unknown ||= []) << key
        end
      end
      raise ArgumentError, "unknown keywords: #{unknown.join(", ")}" if unknown
    else
      args << kw unless kw.empty?
      raise ArgumentError, "struct size differs" if n < argc
      i = 0
      while i < argc
        Primitive.struct_set_raw(i, args[i])
        i += 1
      end
      while i < n
        Primitive.struct_set_raw(i, nil)
        i += 1
      end
    end
    nil
  end

  Primitive.struct_register_generic_init
end
