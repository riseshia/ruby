/**********************************************************************

  struct.c -

  $Author$
  created at: Tue Mar 22 18:44:30 JST 1995

  Copyright (C) 1993-2007 Yukihiro Matsumoto

**********************************************************************/

#include "id.h"
#include "internal.h"
#include "internal/class.h"
#include "internal/error.h"
#include "internal/hash.h"
#include "internal/object.h"
#include "internal/proc.h"
#include "internal/struct.h"
#include "internal/symbol.h"
#include "shape.h"
#include "vm_core.h"
#include "builtin.h"

/* only for struct[:field] access */
enum {
    AREF_HASH_UNIT = 5,
    AREF_HASH_THRESHOLD = 10
};

/* Note: Data is a stricter version of the Struct: no attr writers & no
   hash-alike/array-alike behavior. It shares most of the implementation
   on the C level, but is unrelated on the Ruby level. */
VALUE rb_cStruct;
static VALUE rb_cData;
static ID id_members, id_back_members, id_keyword_init;

static VALUE struct_alloc(VALUE);

// Inline cache for the hidden ivars of Struct / Data classes. Classes made by
// Struct.new or Data.define set these ivars in the same order and so share one
// shape: remembering "this shape -> that field index" per ivar turns the lookup
// into a shape id comparison, like the inline cache of an attr_reader.
// An entry packs the shape id and the index so that it is read and written in
// one piece. 0 is never a valid entry: the root shape has no field, and
// ATTR_INDEX_NOT_SET records that a shape does not have the ivar.
// Two entries per ivar: `class Foo < Struct.new(...)` looks an ivar up on Foo
// and then on its anonymous parent, which have different shapes.
#define HIDDEN_IVAR_CACHE_ENTRIES 2
typedef uint64_t hidden_ivar_cache_t[HIDDEN_IVAR_CACHE_ENTRIES];
static hidden_ivar_cache_t members_cache, back_members_cache, keyword_init_cache;

static VALUE
hidden_ivar_get(VALUE klass, ID id)
{
    uint64_t *cache =
        id == id_members ? members_cache :
        id == id_back_members ? back_members_cache :
        id == id_keyword_init ? keyword_init_cache : NULL;
    VALUE fields_obj = RCLASS_WRITABLE_FIELDS_OBJ(klass);

    if (!cache || !fields_obj) return rb_attr_get(klass, id);

    shape_id_t shape_id = RBASIC_SHAPE_ID_FOR_READ(fields_obj);
    if (rb_shape_complex_p(shape_id)) return rb_attr_get(klass, id);

    uint64_t first = cache[0], second = cache[1];
    attr_index_t index;
    if (first && (shape_id_t)(first >> 32) == shape_id) {
        index = (attr_index_t)first;
    }
    else if (second && (shape_id_t)(second >> 32) == shape_id) {
        index = (attr_index_t)second;
    }
    else {
        if (!rb_shape_get_iv_index(shape_id, id, &index)) index = ATTR_INDEX_NOT_SET;
        cache[1] = first;
        cache[0] = ((uint64_t)shape_id << 32) | index;
    }
    return index == ATTR_INDEX_NOT_SET ? Qnil : rb_imemo_fields_ptr(fields_obj)[index];
}

static inline VALUE
struct_ivar_get(VALUE c, ID id)
{
    VALUE orig = c;
    VALUE ivar = hidden_ivar_get(c, id);

    if (!NIL_P(ivar))
        return ivar;

    for (;;) {
        c = rb_class_superclass(c);
        if (c == rb_cStruct || c == rb_cData || !RTEST(c))
            return Qnil;
        RUBY_ASSERT(RB_TYPE_P(c, T_CLASS));
        ivar = hidden_ivar_get(c, id);
        if (!NIL_P(ivar)) {
            if (!OBJ_FROZEN(orig)) rb_ivar_set(orig, id, ivar);
            return ivar;
        }
    }
}

VALUE
rb_struct_s_keyword_init(VALUE klass)
{
    return struct_ivar_get(klass, id_keyword_init);
}

VALUE
rb_struct_s_members(VALUE klass)
{
    VALUE members = struct_ivar_get(klass, id_members);

    if (NIL_P(members)) {
        rb_raise(rb_eTypeError, "uninitialized struct");
    }
    if (!RB_TYPE_P(members, T_ARRAY)) {
        rb_raise(rb_eTypeError, "corrupted struct");
    }
    return members;
}

VALUE
rb_struct_members(VALUE s)
{
    VALUE members = rb_struct_s_members(rb_obj_class(s));

    if (RSTRUCT_LEN_RAW(s) != RARRAY_LEN(members)) {
        rb_raise(rb_eTypeError, "struct size differs (%"PRIdLEN" required %"PRIdLEN" given)",
                 RARRAY_LEN(members), RSTRUCT_LEN_RAW(s));
    }
    return members;
}

static rb_len_t
struct_member_pos_ideal(VALUE name, rb_len_t mask)
{
    /* (id & (mask/2)) * 2 */
    return (SYM2ID(name) >> (ID_SCOPE_SHIFT - 1)) & mask;
}

static rb_len_t
struct_member_pos_probe(rb_len_t prev, rb_len_t mask)
{
    /* (((prev/2) * AREF_HASH_UNIT + 1) & (mask/2)) * 2 */
    return (prev * AREF_HASH_UNIT + 2) & mask;
}

static VALUE
struct_set_members(VALUE klass, VALUE /* frozen hidden array */ members)
{
    VALUE back;
    const rb_len_t members_length = RARRAY_LEN(members);

    if (members_length <= AREF_HASH_THRESHOLD) {
        back = members;
    }
    else {
        rb_len_t i, j, mask = 64;
        VALUE name;

        while (mask < members_length * AREF_HASH_UNIT) mask *= 2;

        back = rb_ary_hidden_new(mask + 1);
        rb_ary_store(back, mask, INT2FIX(members_length));
        mask -= 2;			  /* mask = (2**k-1)*2 */

        for (i=0; i < members_length; i++) {
            name = RARRAY_AREF(members, i);

            j = struct_member_pos_ideal(name, mask);

            for (;;) {
                if (!RTEST(RARRAY_AREF(back, j))) {
                    rb_ary_store(back, j, name);
                    rb_ary_store(back, j + 1, INT2FIX(i));
                    break;
                }
                j = struct_member_pos_probe(j, mask);
            }
        }
        OBJ_FREEZE(back);
    }
    rb_ivar_set(klass, id_members, members);
    rb_ivar_set(klass, id_back_members, back);

    return members;
}

static inline int
struct_back_members_pos(VALUE back, long len, VALUE name)
{
    rb_len_t j, mask;

    if (UNLIKELY(NIL_P(back))) {
        rb_raise(rb_eTypeError, "uninitialized struct");
    }
    if (UNLIKELY(!RB_TYPE_P(back, T_ARRAY))) {
        rb_raise(rb_eTypeError, "corrupted struct");
    }

    mask = RARRAY_LEN(back);

    if (mask <= AREF_HASH_THRESHOLD) {
        if (UNLIKELY(len != mask)) {
            rb_raise(rb_eTypeError,
                     "struct size differs (%"PRIdLEN" required %"PRIdLEN" given)",
                     mask, len);
        }
        for (j = 0; j < mask; j++) {
            if (RARRAY_AREF(back, j) == name)
                return (int)j;
        }
        return -1;
    }

    if (UNLIKELY(len != FIX2INT(RARRAY_AREF(back, mask-1)))) {
        rb_raise(rb_eTypeError, "struct size differs (%d required %"PRIdLEN" given)",
                 FIX2INT(RARRAY_AREF(back, mask-1)), len);
    }

    mask -= 3;
    j = struct_member_pos_ideal(name, mask);

    for (;;) {
        VALUE e = RARRAY_AREF(back, j);
        if (e == name)
            return FIX2INT(RARRAY_AREF(back, j + 1));
        if (!RTEST(e)) {
            return -1;
        }
        j = struct_member_pos_probe(j, mask);
    }
}

// Whether struct_back_members_pos(back, len, ...) can run without raising.
static bool
struct_back_members_usable_p(VALUE back, long len)
{
    if (!RB_TYPE_P(back, T_ARRAY)) return false;

    long mask = RARRAY_LEN(back);
    if (mask <= AREF_HASH_THRESHOLD) return len == mask;
    return len == FIX2INT(RARRAY_AREF(back, mask-1));
}

static inline int
struct_member_pos_in(VALUE s, VALUE name, VALUE back)
{
    return struct_back_members_pos(back, RSTRUCT_LEN_RAW(s), name);
}

static inline int
struct_member_pos(VALUE s, VALUE name)
{
    return struct_member_pos_in(s, name, struct_ivar_get(rb_obj_class(s), id_back_members));
}

/*
 *  call-seq:
 *    StructClass::members -> array_of_symbols
 *
 *  Returns the member names of the Struct descendant as an array:
 *
 *     Customer = Struct.new(:name, :address, :zip)
 *     Customer.members # => [:name, :address, :zip]
 *
 */

static VALUE
rb_struct_s_members_m(VALUE klass)
{
    VALUE members = rb_struct_s_members(klass);

    return rb_ary_dup(members);
}

/*
 *  call-seq:
 *    members -> array_of_symbols
 *
 *  Returns the member names from +self+ as an array:
 *
 *     Customer = Struct.new(:name, :address, :zip)
 *     Customer.new.members # => [:name, :address, :zip]
 *
 *  Related: #to_a.
 */

static VALUE
rb_struct_members_m(VALUE obj)
{
    return rb_struct_s_members_m(rb_obj_class(obj));
}

VALUE
rb_struct_getmember(VALUE obj, ID id)
{
    VALUE slot = ID2SYM(id);
    int i = struct_member_pos(obj, slot);
    if (i != -1) {
        return RSTRUCT_GET_RAW(obj, i);
    }
    rb_name_err_raise("'%1$s' is not a struct member", obj, ID2SYM(id));

    UNREACHABLE_RETURN(Qnil);
}

static void
rb_struct_modify(VALUE s)
{
    rb_check_frozen(s);
}

static VALUE
anonymous_struct(VALUE klass)
{
    VALUE nstr;

    nstr = rb_class_new(klass);
    rb_make_metaclass(nstr, RBASIC(klass)->klass);
    rb_class_inherited(klass, nstr);
    return nstr;
}

static VALUE
new_struct(VALUE name, VALUE super)
{
    /* old style: should we warn? */
    ID id;
    name = rb_str_to_str(name);
    if (!rb_is_const_name(name)) {
        rb_name_err_raise("identifier %1$s needs to be constant",
                          super, name);
    }
    id = rb_to_id(name);
    if (rb_const_defined_at(super, id)) {
        rb_warn("redefining constant %"PRIsVALUE"::%"PRIsVALUE, super, name);
        rb_mod_remove_const(super, ID2SYM(id));
    }
    return rb_define_class_id_under_no_pin(super, id, super);
}

NORETURN(static void invalid_struct_pos(VALUE s, VALUE idx));

static void
define_aref_method(VALUE nstr, VALUE name, VALUE off)
{
    rb_add_method_optimized(nstr, SYM2ID(name), OPTIMIZED_METHOD_TYPE_STRUCT_AREF, FIX2UINT(off), METHOD_VISI_PUBLIC);
}

void
rb_struct_define_aref_method(VALUE nstr, ID name, unsigned int off)
{
    rb_add_method_optimized(nstr, name, OPTIMIZED_METHOD_TYPE_STRUCT_AREF, off, METHOD_VISI_PUBLIC);
}

static void
define_aset_method(VALUE nstr, VALUE name, VALUE off)
{
    rb_add_method_optimized(nstr, SYM2ID(name), OPTIMIZED_METHOD_TYPE_STRUCT_ASET, FIX2UINT(off), METHOD_VISI_PUBLIC);
}

static VALUE
rb_struct_s_inspect(VALUE klass)
{
    VALUE inspect = rb_class_name(klass);
    if (RTEST(rb_struct_s_keyword_init(klass))) {
        rb_str_cat_cstr(inspect, "(keyword_init: true)");
    }
    return inspect;
}

#define KEYWORD_POSITIONS_MAX 64

struct keyword_positions {
    VALUE back_members;
    long len;
    int count;
    int positions[KEYWORD_POSITIONS_MAX];
    VALUE values[KEYWORD_POSITIONS_MAX];
};

static int
keyword_positions_i(st_data_t key, st_data_t val, st_data_t ptr)
{
    struct keyword_positions *kw = (struct keyword_positions *)ptr;
    VALUE name = (VALUE)key;
    int pos = SYMBOL_P(name) ? struct_back_members_pos(kw->back_members, kw->len, name) : -1;

    if (pos < 0 || kw->count == KEYWORD_POSITIONS_MAX) {
        kw->count = -1;
        return ST_STOP;
    }
    kw->positions[kw->count] = pos;
    kw->values[kw->count] = (VALUE)val;
    kw->count++;
    return ST_CONTINUE;
}

// Resolves every key of +hash+ to a member position of +klass+ (which has +len+
// members), provided all of them are Symbols naming a member. That runs no Ruby code and changes nothing, so the
// Hash can be walked without the rb_ensure() rb_hash_foreach() sets up. On
// false the caller goes on as if this had not been tried.
static bool
resolve_keyword_positions(VALUE klass, long len, VALUE hash, struct keyword_positions *kw)
{
    // Only the header: the arrays are filled up to count, and a compound literal
    // would clear all of them (some 800 bytes) on every call.
    kw->back_members = struct_ivar_get(klass, id_back_members);
    kw->len = len;
    kw->count = 0;
    // An inconsistent class is left to the regular path, which raises for it.
    if (!struct_back_members_usable_p(kw->back_members, len)) return false;

    rb_hash_stlike_foreach(hash, keyword_positions_i, (st_data_t)kw);
    return kw->count >= 0;
}

// With every member given, the built-in Data#initialize cannot raise and runs
// no Ruby code, so the only traces of calling it are its c_call / c_return
// events. Without a hook for those, filling the members directly is
// indistinguishable from building the keyword Hash and calling it.
static bool
data_initialize_unobservable_p(VALUE klass)
{
    return ruby_vm_c_events_enabled == 0 && rb_method_basic_definition_p(klass, idInitialize);
}

static VALUE
data_initialize_positional(VALUE self, VALUE members, int argc, const VALUE *argv)
{
    VALUE arg_hash = rb_hash_new_capa(argc);
    for (long i = 0; i < argc; i++) {
        rb_hash_aset(arg_hash, rb_ary_entry(members, i), argv[i]);
    }
    rb_obj_call_init_kw(self, 1, &arg_hash, RB_PASS_KEYWORDS);
    return self;
}

static VALUE
rb_data_s_new(int argc, const VALUE *argv, VALUE klass)
{
    if (rb_keyword_given_p()) {
        if (argc > 1 || !RB_TYPE_P(argv[0], T_HASH)) {
            rb_error_arity(argc, 0, 0);
        }
        if (data_initialize_unobservable_p(klass)) {
            // Same as the positional case below: with every member named once the
            // built-in initialize can only fill the members and freeze. Keywords
            // are resolved before allocating so that giving up leaves no instance.
            long num_members = RARRAY_LEN(struct_ivar_get(klass, id_members));
            struct keyword_positions kw;
            if (resolve_keyword_positions(klass, num_members, argv[0], &kw) && kw.count == num_members) {
                VALUE self = rb_obj_alloc(klass);
                if (RB_TYPE_P(self, T_STRUCT) && RSTRUCT_LEN_RAW(self) == num_members && !OBJ_FROZEN(self)) {
                    for (int i = 0; i < kw.count; i++) {
                        RSTRUCT_SET_RAW(self, kw.positions[i], kw.values[i]);
                    }
                    OBJ_FREEZE(self);
                    return self;
                }
                rb_obj_call_init_kw(self, argc, argv, RB_PASS_KEYWORDS);
                return self;
            }
        }
        return rb_class_new_instance_pass_kw(argc, argv, klass);
    }
    else {
        VALUE members = struct_ivar_get(klass, id_members);
        int num_members = RARRAY_LENINT(members);

        rb_check_arity(argc, 0, num_members);
        if (argc == num_members && data_initialize_unobservable_p(klass)) {
            VALUE self = rb_obj_alloc(klass);
            if (RB_TYPE_P(self, T_STRUCT) && RSTRUCT_LEN_RAW(self) == argc && !OBJ_FROZEN(self)) {
                for (long i = 0; i < argc; i++) {
                    RSTRUCT_SET_RAW(self, i, argv[i]);
                }
                OBJ_FREEZE(self);
                return self;
            }
            return data_initialize_positional(self, members, argc, argv);
        }
        VALUE arg_hash = rb_hash_new_capa(argc);
        for (rb_len_t i=0; i<argc; i++) {
            VALUE k = rb_ary_entry(members, i), v = argv[i];
            rb_hash_aset(arg_hash, k, v);
        }
        return rb_class_new_instance_kw(1, &arg_hash, klass, RB_PASS_KEYWORDS);
    }
}

#if 0 /* for RDoc */

/*
 * call-seq:
 *   StructClass::keyword_init? -> true or falsy value
 *
 * Returns +true+ if the class was initialized with <tt>keyword_init: true</tt>.
 * Otherwise returns +nil+ or +false+.
 *
 * Examples:
 *   Foo = Struct.new(:a)
 *   Foo.keyword_init? # => nil
 *   Bar = Struct.new(:a, keyword_init: true)
 *   Bar.keyword_init? # => true
 *   Baz = Struct.new(:a, keyword_init: false)
 *   Baz.keyword_init? # => false
 */
static VALUE
rb_struct_s_keyword_init_p(VALUE obj)
{
}
#endif

#define rb_struct_s_keyword_init_p rb_struct_s_keyword_init

static VALUE
setup_struct(VALUE nstr, VALUE members)
{
    rb_len_t i, len;

    members = struct_set_members(nstr, members);

    rb_define_alloc_func(nstr, struct_alloc);
    rb_define_singleton_method(nstr, "new", rb_class_new_instance_pass_kw, -1);
    rb_define_singleton_method(nstr, "[]", rb_class_new_instance_pass_kw, -1);
    rb_define_singleton_method(nstr, "members", rb_struct_s_members_m, 0);
    rb_define_singleton_method(nstr, "inspect", rb_struct_s_inspect, 0);
    rb_define_singleton_method(nstr, "keyword_init?", rb_struct_s_keyword_init_p, 0);

    len = RARRAY_LEN(members);
    for (i=0; i< len; i++) {
        VALUE sym = RARRAY_AREF(members, i);
        ID id = SYM2ID(sym);
        VALUE off = LEN2NUM(i);

        define_aref_method(nstr, sym, off);
        define_aset_method(nstr, ID2SYM(rb_id_attrset(id)), off);
    }

    return nstr;
}

static VALUE
setup_data(VALUE subclass, VALUE members)
{
    rb_len_t i, len;

    members = struct_set_members(subclass, members);

    rb_define_alloc_func(subclass, struct_alloc);
    VALUE sclass = rb_singleton_class(subclass);
    rb_undef_method(sclass, "define");
    rb_define_method(sclass, "new", rb_data_s_new, -1);
    rb_define_method(sclass, "[]", rb_data_s_new, -1);
    rb_define_method(sclass, "members", rb_struct_s_members_m, 0);
    rb_define_method(sclass, "inspect", rb_struct_s_inspect, 0); // FIXME: just a separate method?..

    len = RARRAY_LEN(members);
    for (i=0; i< len; i++) {
        VALUE sym = RARRAY_AREF(members, i);
        VALUE off = LEN2NUM(i);

        define_aref_method(subclass, sym, off);
    }

    return subclass;
}

VALUE
rb_struct_alloc_noinit(VALUE klass)
{
    return struct_alloc(klass);
}

static VALUE
struct_make_members_list(va_list ar)
{
    char *mem;
    VALUE ary, list = rb_ident_hash_new();
    RBASIC_CLEAR_CLASS(list);
    while ((mem = va_arg(ar, char*)) != 0) {
        VALUE sym = rb_sym_intern_ascii_cstr(mem);
        if (RTEST(rb_hash_has_key(list, sym))) {
            rb_raise(rb_eArgError, "duplicate member: %s", mem);
        }
        rb_hash_aset(list, sym, Qtrue);
    }
    ary = rb_hash_keys(list);
    RBASIC_CLEAR_CLASS(ary);
    OBJ_FREEZE(ary);
    return ary;
}

static VALUE
struct_define_without_accessor(VALUE outer, const char *class_name, VALUE super, rb_alloc_func_t alloc, VALUE members)
{
    VALUE klass;

    if (class_name) {
        if (outer) {
            klass = rb_define_class_under(outer, class_name, super);
        }
        else {
            klass = rb_define_class(class_name, super);
        }
    }
    else {
        klass = anonymous_struct(super);
    }

    struct_set_members(klass, members);

    if (alloc) {
        rb_define_alloc_func(klass, alloc);
    }
    else {
        rb_define_alloc_func(klass, struct_alloc);
    }

    return klass;
}

VALUE
rb_struct_define_without_accessor_under(VALUE outer, const char *class_name, VALUE super, rb_alloc_func_t alloc, ...)
{
    va_list ar;
    VALUE members;

    va_start(ar, alloc);
    members = struct_make_members_list(ar);
    va_end(ar);

    return struct_define_without_accessor(outer, class_name, super, alloc, members);
}

VALUE
rb_struct_define_without_accessor(const char *class_name, VALUE super, rb_alloc_func_t alloc, ...)
{
    va_list ar;
    VALUE members;

    va_start(ar, alloc);
    members = struct_make_members_list(ar);
    va_end(ar);

    return struct_define_without_accessor(0, class_name, super, alloc, members);
}

VALUE
rb_struct_define(const char *name, ...)
{
    va_list ar;
    VALUE st, ary;

    va_start(ar, name);
    ary = struct_make_members_list(ar);
    va_end(ar);

    if (!name) {
        st = anonymous_struct(rb_cStruct);
    }
    else {
        st = new_struct(rb_str_new2(name), rb_cStruct);
        rb_vm_register_global_object(st);
    }
    return setup_struct(st, ary);
}

VALUE
rb_struct_define_under(VALUE outer, const char *name, ...)
{
    va_list ar;
    VALUE ary;

    va_start(ar, name);
    ary = struct_make_members_list(ar);
    va_end(ar);

    return setup_struct(rb_define_class_id_under(outer, rb_intern(name), rb_cStruct), ary);
}

/*
 *  call-seq:
 *    Struct.new(*member_names, keyword_init: nil){|Struct_subclass| ... } -> Struct_subclass
 *    Struct.new(class_name, *member_names, keyword_init: nil){|Struct_subclass| ... } -> Struct_subclass
 *    Struct_subclass.new(*member_names) -> Struct_subclass_instance
 *    Struct_subclass.new(**member_names) -> Struct_subclass_instance
 *
 *  <tt>Struct.new</tt> returns a new subclass of +Struct+.  The new subclass:
 *
 *  - May be anonymous, or may have the name given by +class_name+.
 *  - May have members as given by +member_names+.
 *  - May have initialization via ordinary arguments, or via keyword arguments
 *
 *  The new subclass has its own method <tt>::new</tt>; thus:
 *
 *    Foo = Struct.new('Foo', :foo, :bar) # => Struct::Foo
 *    f = Foo.new(0, 1)                   # => #<struct Struct::Foo foo=0, bar=1>
 *
 *  <b>Class Name</b>
 *
 *  With string argument +class_name+,
 *  returns a new subclass of +Struct+ named <tt>Struct::<em>class_name</em></tt>:
 *
 *    Foo = Struct.new('Foo', :foo, :bar) # => Struct::Foo
 *    Foo.name                            # => "Struct::Foo"
 *    Foo.superclass                      # => Struct
 *
 *  Without string argument +class_name+,
 *  returns a new anonymous subclass of +Struct+:
 *
 *    Struct.new(:foo, :bar).name # => nil
 *
 *  <b>Block</b>
 *
 *  With a block given, the created subclass is yielded to the block:
 *
 *    Customer = Struct.new('Customer', :name, :address) do |new_class|
 *      p "The new subclass is #{new_class}"
 *      def greeting
 *        "Hello #{name} at #{address}"
 *      end
 *    end           # => Struct::Customer
 *    dave = Customer.new('Dave', '123 Main')
 *    dave # =>     #<struct Struct::Customer name="Dave", address="123 Main">
 *    dave.greeting # => "Hello Dave at 123 Main"
 *
 *  Output, from <tt>Struct.new</tt>:
 *
 *    "The new subclass is Struct::Customer"
 *
 *  <b>Member Names</b>
 *
 *  Symbol arguments +member_names+
 *  determines the members of the new subclass:
 *
 *    Struct.new(:foo, :bar).members        # => [:foo, :bar]
 *    Struct.new('Foo', :foo, :bar).members # => [:foo, :bar]
 *
 *  The new subclass has instance methods corresponding to +member_names+:
 *
 *    Foo = Struct.new('Foo', :foo, :bar)
 *    Foo.instance_methods(false) # => [:foo, :bar, :foo=, :bar=]
 *    f = Foo.new                 # => #<struct Struct::Foo foo=nil, bar=nil>
 *    f.foo                       # => nil
 *    f.foo = 0                   # => 0
 *    f.bar                       # => nil
 *    f.bar = 1                   # => 1
 *    f                           # => #<struct Struct::Foo foo=0, bar=1>
 *
 *  <b>Singleton Methods</b>
 *
 *  A subclass returned by Struct.new has these singleton methods:
 *
 *  - Method <tt>::new </tt> creates an instance of the subclass:
 *
 *      Foo.new          # => #<struct Struct::Foo foo=nil, bar=nil>
 *      Foo.new(0)       # => #<struct Struct::Foo foo=0, bar=nil>
 *      Foo.new(0, 1)    # => #<struct Struct::Foo foo=0, bar=1>
 *      Foo.new(0, 1, 2) # Raises ArgumentError: struct size differs
 *
 *      # Initialization with keyword arguments:
 *      Foo.new(foo: 0)         # => #<struct Struct::Foo foo=0, bar=nil>
 *      Foo.new(foo: 0, bar: 1) # => #<struct Struct::Foo foo=0, bar=1>
 *      Foo.new(foo: 0, bar: 1, baz: 2)
 *      # Raises ArgumentError: unknown keywords: baz
 *
 *  - Method <tt>:inspect</tt> returns a string representation of the subclass:
 *
 *      Foo.inspect
 *      # => "Struct::Foo"
 *
 *  - Method <tt>::members</tt> returns an array of the member names:
 *
 *      Foo.members # => [:foo, :bar]
 *
 *  <b>Keyword Argument</b>
 *
 *  By default, the arguments for initializing an instance of the new subclass
 *  can be both positional and keyword arguments.
 *
 *  Optional keyword argument <tt>keyword_init:</tt> allows to force only one
 *  type of arguments to be accepted:
 *
 *    KeywordsOnly = Struct.new(:foo, :bar, keyword_init: true)
 *    KeywordsOnly.new(bar: 1, foo: 0)
 *    # => #<struct KeywordsOnly foo=0, bar=1>
 *    KeywordsOnly.new(0, 1)
 *    # Raises ArgumentError: wrong number of arguments
 *
 *    PositionalOnly = Struct.new(:foo, :bar, keyword_init: false)
 *    PositionalOnly.new(0, 1)
 *    # => #<struct PositionalOnly foo=0, bar=1>
 *    PositionalOnly.new(bar: 1, foo: 0)
 *    # => #<struct PositionalOnly foo={foo: 1, bar: 2}, bar=nil>
 *    # Note that no error is raised, but arguments treated as one hash value
 *
 *    # Same as not providing keyword_init:
 *    Any = Struct.new(:foo, :bar, keyword_init: nil)
 *    Any.new(foo: 1, bar: 2)
 *    # => #<struct Any foo=1, bar=2>
 *    Any.new(1, 2)
 *    # => #<struct Any foo=1, bar=2>
 */

static VALUE
rb_struct_s_def(int argc, VALUE *argv, VALUE klass)
{
    VALUE name = Qnil, rest, keyword_init = Qnil;
    rb_len_t i;
    VALUE st;
    VALUE opt;

    argc = rb_scan_args(argc, argv, "0*:", NULL, &opt);
    if (argc >= 1 && !SYMBOL_P(argv[0])) {
        name = argv[0];
        --argc;
        ++argv;
    }

    if (!NIL_P(opt)) {
        static ID keyword_ids[1];

        if (!keyword_ids[0]) {
            keyword_ids[0] = rb_intern("keyword_init");
        }
        rb_get_kwargs(opt, keyword_ids, 0, 1, &keyword_init);
        if (UNDEF_P(keyword_init)) {
            keyword_init = Qnil;
        }
        else if (RTEST(keyword_init)) {
            keyword_init = Qtrue;
        }
    }

    rest = rb_ident_hash_new();
    RBASIC_CLEAR_CLASS(rest);
    for (i=0; i<argc; i++) {
        VALUE mem = rb_to_symbol(argv[i]);
        if (rb_is_attrset_sym(mem)) {
            rb_raise(rb_eArgError, "invalid struct member: %"PRIsVALUE, mem);
        }
        if (RTEST(rb_hash_has_key(rest, mem))) {
            rb_raise(rb_eArgError, "duplicate member: %"PRIsVALUE, mem);
        }
        rb_hash_aset(rest, mem, Qtrue);
    }
    rest = rb_hash_keys(rest);
    RBASIC_CLEAR_CLASS(rest);
    OBJ_FREEZE(rest);
    if (NIL_P(name)) {
        st = anonymous_struct(klass);
    }
    else {
        st = new_struct(name, klass);
    }
    setup_struct(st, rest);
    rb_ivar_set(st, id_keyword_init, keyword_init);
    if (rb_block_given_p()) {
        rb_mod_module_eval(0, 0, st);
    }

    return st;
}

static rb_len_t
num_members(VALUE klass)
{
    VALUE members;
    members = struct_ivar_get(klass, id_members);
    if (!RB_TYPE_P(members, T_ARRAY)) {
        rb_bug("broken members"); /* should never happen */
    }
    return RARRAY_LEN(members);
}

rb_len_t
rb_zjit_struct_num_members(VALUE klass)
{
    return num_members(klass);
}

/*
 */

struct struct_hash_set_arg {
    VALUE self;
    VALUE unknown_keywords;
    VALUE back_members;
    char *found;
    rb_len_t missing_count;
};

static int rb_struct_pos(VALUE s, VALUE *name, bool name_only);
static int struct_pos_cached(VALUE s, VALUE *name, bool name_only, VALUE *back);
static VALUE deconstruct_keys(VALUE s, VALUE keys, bool name_only, bool block_given);

static int
struct_hash_aset(VALUE key, VALUE val, struct struct_hash_set_arg *args, bool name_only)
{
    int i = struct_pos_cached(args->self, &key, name_only, &args->back_members);
    if (i < 0) {
        if (NIL_P(args->unknown_keywords)) {
            args->unknown_keywords = rb_ary_new();
        }
        rb_ary_push(args->unknown_keywords, key);
    }
    else {
        rb_struct_modify(args->self);
        RSTRUCT_SET_RAW(args->self, i, val);
    }
    return i;
}

static int
struct_hash_set_i(VALUE key, VALUE val, VALUE arg)
{
    struct struct_hash_set_arg *args = (struct struct_hash_set_arg *)arg;
    struct_hash_aset(key, val, args, false);
    return ST_CONTINUE;
}

static VALUE
rb_struct_initialize_m(int argc, const VALUE *argv, VALUE self)
{
    VALUE klass = rb_obj_class(self);
    rb_struct_modify(self);
    // struct_alloc() sized self from num_members(klass), so the length is already at hand.
    rb_len_t n = RSTRUCT_LEN_RAW(self);
    if (argc == 0) {
        rb_mem_clear((VALUE *)RSTRUCT_CONST_PTR(self), n);
        return Qnil;
    }

    bool keyword_init = false;
    switch (rb_struct_s_keyword_init(klass)) {
      default:
        if (argc > 1 || !RB_TYPE_P(argv[0], T_HASH)) {
            rb_error_arity(argc, 0, 0);
        }
        keyword_init = true;
        break;
      case Qfalse:
        break;
      case Qnil:
        if (argc > 1 || !RB_TYPE_P(argv[0], T_HASH)) {
            break;
        }
        keyword_init = rb_keyword_given_p();
        break;
    }
    struct keyword_positions kw;
    if (keyword_init && resolve_keyword_positions(klass, n, argv[0], &kw)) {
        rb_mem_clear((VALUE *)RSTRUCT_CONST_PTR(self), n);
        for (int i = 0; i < kw.count; i++) {
            RSTRUCT_SET_RAW(self, kw.positions[i], kw.values[i]);
        }
    }
    else if (keyword_init) {
        struct struct_hash_set_arg arg = {
            .self = self,
            .unknown_keywords = Qnil,
        };
        rb_mem_clear((VALUE *)RSTRUCT_CONST_PTR(self), n);
        rb_hash_foreach(argv[0], struct_hash_set_i, (VALUE)&arg);
        if (UNLIKELY(!NIL_P(arg.unknown_keywords))) {
            rb_raise(rb_eArgError, "unknown keywords: %"PRIsVALUE,
                     rb_ary_join(arg.unknown_keywords, rb_str_new2(", ")));
        }
    }
    else {
        if (n < argc) {
            rb_raise(rb_eArgError, "struct size differs");
        }
        for (rb_len_t i=0; i<argc; i++) {
            RSTRUCT_SET_RAW(self, i, argv[i]);
        }
        if (n > argc) {
            rb_mem_clear((VALUE *)RSTRUCT_CONST_PTR(self)+argc, n-argc);
        }
    }
    return Qnil;
}

VALUE
rb_struct_initialize(VALUE self, VALUE values)
{
    rb_struct_initialize_m(RARRAY_LENINT(values), RARRAY_CONST_PTR(values), self);
    if (rb_obj_is_kind_of(self, rb_cData)) OBJ_FREEZE(self);
    RB_GC_GUARD(values);
    return Qnil;
}

static VALUE *
struct_heap_alloc(VALUE st, size_t len)
{
    return ALLOC_N(VALUE, len);
}

STATIC_ASSERT(robject_rstruct_fields_offset, offsetof(struct RObject, as.extended) == offsetof(struct RStruct, fields_obj));

static inline bool
struct_embedded_p(rb_len_t n)
{
    size_t embedded_size = offsetof(struct RStruct, as.ary) + (sizeof(VALUE) * n);
    const rb_len_t embed_len_max = RSTRUCT_EMBED_LEN_MASK >> RSTRUCT_EMBED_LEN_SHIFT;
    return n > 0 && n <= embed_len_max && rb_gc_size_allocatable_p(embedded_size);
}

bool
rb_zjit_struct_embedded_p(rb_len_t num_members)
{
    return struct_embedded_p(num_members);
}

static VALUE
struct_alloc(VALUE klass)
{
    rb_len_t n = num_members(klass);
    size_t embedded_size = offsetof(struct RStruct, as.ary) + (sizeof(VALUE) * n);
    VALUE flags = T_STRUCT;

    if (struct_embedded_p(n)) {
        flags |= n << RSTRUCT_EMBED_LEN_SHIFT;

        VALUE st = rb_newobj(GET_EC(), klass, flags, ROOT_SHAPE_ID | SHAPE_ID_LAYOUT_EXTENDED, true, embedded_size);
        RSTRUCT_SET_FIELDS_OBJ(st, 0);
        rb_mem_clear((VALUE *)RSTRUCT(st)->as.ary, n);

        return st;
    }
    else {
        VALUE obj = rb_newobj(GET_EC(), klass, flags, ROOT_SHAPE_ID | SHAPE_ID_LAYOUT_EXTENDED, true, sizeof(struct RStruct));
        struct RStruct *st = RSTRUCT(obj);

        st->fields_obj = 0;
        st->as.heap.ptr = NULL;
        st->as.heap.len = 0;

        st->as.heap.ptr = struct_heap_alloc((VALUE)st, n);
        rb_mem_clear((VALUE *)st->as.heap.ptr, n);
        st->as.heap.len = n;

        return obj;
    }
}

// Whether `klass` allocates its instances with struct_alloc.
bool
rb_zjit_class_has_struct_allocator(VALUE klass)
{
    return rb_get_alloc_func(klass) == struct_alloc;
}

// The ID of the `index`th member of the Struct class `klass`. `index` must be in bounds
// according to rb_zjit_struct_num_members().
ID
rb_zjit_struct_member_id(VALUE klass, rb_len_t index)
{
    VALUE members = struct_ivar_get(klass, id_members);
    RUBY_ASSERT(RB_TYPE_P(members, T_ARRAY));
    RUBY_ASSERT(index >= 0 && index < RARRAY_LEN(members));
    return SYM2ID(RARRAY_AREF(members, index));
}

VALUE
rb_struct_alloc(VALUE klass, VALUE values)
{
    return rb_class_new_instance(RARRAY_LENINT(values), RARRAY_CONST_PTR(values), klass);
}

VALUE
rb_struct_new(VALUE klass, ...)
{
    VALUE tmpargs[16], *mem = tmpargs;
    int size, i;
    va_list args;

    size = rb_len2int(num_members(klass));
    if (size > numberof(tmpargs)) {
        tmpargs[0] = rb_ary_hidden_new(size);
        mem = RARRAY_PTR(tmpargs[0]);
    }
    va_start(args, klass);
    for (i=0; i<size; i++) {
        mem[i] = va_arg(args, VALUE);
    }
    va_end(args);

    return rb_class_new_instance(size, mem, klass);
}

static VALUE
struct_enum_size(VALUE s, VALUE args, VALUE eobj)
{
    return rb_struct_size(s);
}

/*
 *  call-seq:
 *    each {|value| ... } -> self
 *    each -> enumerator
 *
 *  Calls the given block with the value of each member; returns +self+:
 *
 *    Customer = Struct.new(:name, :address, :zip)
 *    joe = Customer.new("Joe Smith", "123 Maple, Anytown NC", 12345)
 *    joe.each {|value| p value }
 *
 *  Output:
 *
 *    "Joe Smith"
 *    "123 Maple, Anytown NC"
 *    12345
 *
 *  Returns an Enumerator if no block is given.
 *
 *  Related: #each_pair.
 */

static VALUE
rb_struct_each(VALUE s)
{
    rb_len_t i;

    RETURN_SIZED_ENUMERATOR(s, 0, 0, struct_enum_size);
    for (i=0; i<RSTRUCT_LEN_RAW(s); i++) {
        rb_yield(RSTRUCT_GET_RAW(s, i));
    }
    return s;
}

/*
 *  call-seq:
 *    each_pair {|(name, value)| ... } -> self
 *    each_pair -> enumerator
 *
 *  Calls the given block with each member name/value pair; returns +self+:
 *
 *    Customer = Struct.new(:name, :address, :zip) # => Customer
 *    joe = Customer.new("Joe Smith", "123 Maple, Anytown NC", 12345)
 *    joe.each_pair {|(name, value)| p "#{name} => #{value}" }
 *
 *  Output:
 *
 *    "name => Joe Smith"
 *    "address => 123 Maple, Anytown NC"
 *    "zip => 12345"
 *
 *  Returns an Enumerator if no block is given.
 *
 *  Related: #each.
 *
 */

static VALUE
rb_struct_each_pair(VALUE s)
{
    VALUE members;
    rb_len_t i;

    RETURN_SIZED_ENUMERATOR(s, 0, 0, struct_enum_size);
    members = rb_struct_members(s);
    if (rb_block_pair_yield_optimizable()) {
        for (i=0; i<RSTRUCT_LEN_RAW(s); i++) {
            VALUE key = rb_ary_entry(members, i);
            VALUE value = RSTRUCT_GET_RAW(s, i);
            rb_yield_values(2, key, value);
        }
    }
    else {
        for (i=0; i<RSTRUCT_LEN_RAW(s); i++) {
            VALUE key = rb_ary_entry(members, i);
            VALUE value = RSTRUCT_GET_RAW(s, i);
            rb_yield(rb_assoc_new(key, value));
        }
    }
    return s;
}

// The result grows by a name, a value and punctuation per member; start with
// room for that instead of growing out of an embedded String step by step.
static VALUE
inspect_struct_prefix(VALUE s, const char *prefix)
{
    VALUE str = rb_str_buf_new(32 + 16 * RSTRUCT_LEN_RAW(s));
    rb_str_cat_cstr(str, prefix);
    return str;
}

// Members whose inspect cannot run Ruby code or come back to the struct when it is
// the built-in C function: Integer, Float, String, Symbol, nil, true and false.
// That function is looked up at most once per kind and Struct#inspect; with no one
// listening for the call either, it is called directly (or, for a Fixnum, nil, true
// and false, not at all: the text is written straight into the buffer).
enum inspect_direct_kind {
    INSPECT_DIRECT_FIXNUM, INSPECT_DIRECT_BIGNUM, INSPECT_DIRECT_FLOAT, INSPECT_DIRECT_STRING,
    INSPECT_DIRECT_SYMBOL, INSPECT_DIRECT_NIL, INSPECT_DIRECT_TRUE, INSPECT_DIRECT_FALSE,
    INSPECT_DIRECT_KINDS
};

struct inspect_direct {
    const rb_method_cfunc_t *cfunc[INSPECT_DIRECT_KINDS]; // NULL: not looked up yet
    bool nested; // members that are structs have been checked to be writable in place
};

static const rb_method_cfunc_t inspect_direct_none;

static const rb_method_cfunc_t *
inspect_direct_cfunc(struct inspect_direct *direct, VALUE value)
{
    static ID id_inspect;
    enum inspect_direct_kind kind;

    if (FIXNUM_P(value)) kind = INSPECT_DIRECT_FIXNUM;
    else if (NIL_P(value)) kind = INSPECT_DIRECT_NIL;
    else if (value == Qtrue) kind = INSPECT_DIRECT_TRUE;
    else if (value == Qfalse) kind = INSPECT_DIRECT_FALSE;
    else if (SYMBOL_P(value)) kind = INSPECT_DIRECT_SYMBOL;
    else if (RB_FLOAT_TYPE_P(value)) kind = INSPECT_DIRECT_FLOAT;
    else if (SPECIAL_CONST_P(value)) return NULL;
    else if (RBASIC_CLASS(value) == rb_cString) kind = INSPECT_DIRECT_STRING;
    else if (RB_BIGNUM_TYPE_P(value) && RBASIC_CLASS(value) == rb_cInteger) kind = INSPECT_DIRECT_BIGNUM;
    else return NULL;

    if (!direct->cfunc[kind]) {
        if (!id_inspect) id_inspect = rb_intern("inspect");
        const rb_callable_method_entry_t *cme = ruby_vm_c_events_enabled == 0 ?
            rb_callable_method_entry(CLASS_OF(value), id_inspect) : NULL;
        bool builtin = cme && METHOD_ENTRY_BASIC(cme) && cme->def->type == VM_METHOD_TYPE_CFUNC &&
            (cme->def->body.cfunc.argc == 0 || cme->def->body.cfunc.argc == -1);
        direct->cfunc[kind] = builtin ? &cme->def->body.cfunc : &inspect_direct_none;
    }
    return direct->cfunc[kind] == &inspect_direct_none ? NULL : direct->cfunc[kind];
}

// Raw bytes on their way into the result. Appending each piece (", ", a name, "=", a
// number) on its own costs more than the bytes do, so they are collected here and appended
// together. Whatever looks at the String itself flushes first: rb_str_append() settles the
// encoding by what the String holds.
struct inspect_bytes {
    VALUE str;
    long len;
    char bytes[160];
};

static void
inspect_bytes_flush(struct inspect_bytes *out)
{
    if (out->len > 0) {
        rb_str_buf_cat(out->str, out->bytes, out->len);
        out->len = 0;
    }
}

static void
inspect_bytes_cat(struct inspect_bytes *out, const char *ptr, long len)
{
    if (len > (long)sizeof(out->bytes) - out->len) {
        inspect_bytes_flush(out);
        if (len > (long)sizeof(out->bytes)) {
            rb_str_buf_cat(out->str, ptr, len);
            return;
        }
    }
    memcpy(out->bytes + out->len, ptr, len);
    out->len += len;
}

static void
inspect_bytes_append(struct inspect_bytes *out, VALUE text)
{
    inspect_bytes_flush(out);
    rb_str_append(out->str, text);
}

// Appends what rb_str_append(str, rb_inspect(value)) would. The text of a Fixnum,
// nil, true and false is ASCII, so for an ASCII compatible String appending the
// bytes is all rb_str_append() would do.
static void
inspect_struct_append_value(struct inspect_direct *direct, struct inspect_bytes *out, VALUE value)
{
    const rb_method_cfunc_t *cfunc = inspect_direct_cfunc(direct, value);
    VALUE str = out->str;

    if (!cfunc) {
        // rb_inspect() may run anything; the bytes so far belong in the String before that
        inspect_bytes_flush(out);
        rb_str_append(str, rb_inspect(value));
    }
    else if (FIXNUM_P(value) && rb_enc_asciicompat(rb_enc_get(str))) {
        char buf[sizeof(long) * CHAR_BIT / 3 + 3], *end = buf + sizeof(buf), *p = end;
        long n = FIX2LONG(value);
        unsigned long u = n < 0 ? 0UL - (unsigned long)n : (unsigned long)n;
        do { *--p = (char)('0' + u % 10); } while (u /= 10);
        if (n < 0) *--p = '-';
        inspect_bytes_cat(out, p, end - p);
    }
    else if ((NIL_P(value) || value == Qtrue || value == Qfalse) && rb_enc_asciicompat(rb_enc_get(str))) {
        const char *text = NIL_P(value) ? "nil" : value == Qtrue ? "true" : "false";
        inspect_bytes_cat(out, text, (long)strlen(text));
    }
    else {
        VALUE text = cfunc->argc == 0 ?
            ((VALUE (*)(VALUE))cfunc->func)(value) :
            ((VALUE (*)(int, const VALUE *, VALUE))cfunc->func)(0, NULL, value);
        // Only the text of a Symbol can be in an encoding rb_inspect() would not let
        // through: rb_str_inspect() already answers in the right one, numbers are ASCII.
        inspect_bytes_append(out, SYMBOL_P(value) ? rb_inspect_result(text) : text);
    }
}

static VALUE rb_struct_inspect(VALUE s);
static VALUE rb_data_inspect(VALUE s);

#define INSPECT_NESTED_DEPTH_MAX 3

// "#<struct" or "#<data" when inspect of +s+ is the built-in one, NULL otherwise
static const char *
inspect_struct_builtin_prefix(VALUE s)
{
    static ID id_inspect;
    if (!id_inspect) id_inspect = rb_intern("inspect");

    const rb_callable_method_entry_t *cme = rb_callable_method_entry(CLASS_OF(s), id_inspect);
    if (!cme || cme->def->type != VM_METHOD_TYPE_CFUNC) return NULL;
    if (cme->def->body.cfunc.func == (rb_cfunc_t)rb_struct_inspect) return "#<struct";
    if (cme->def->body.cfunc.func == (rb_cfunc_t)rb_data_inspect) return "#<data";
    return NULL;
}

// Whether the text of a member that is a Struct / Data can be written as part of the text
// of the struct holding it: built-in inspect, nobody listening for the call, and nothing
// in its class or member names that rb_inspect() would have to look at (they are ASCII).
static bool
inspect_struct_nested_p(VALUE s)
{
    if (ruby_vm_c_events_enabled > 0 || !inspect_struct_builtin_prefix(s)) return false;

    VALUE klass = rb_obj_class(s);
    if (!rb_enc_str_asciionly_p(rb_class_path(klass))) return false;

    VALUE members = struct_ivar_get(klass, id_members);
    if (!RB_TYPE_P(members, T_ARRAY) || RARRAY_LEN(members) != RSTRUCT_LEN_RAW(s)) return false;
    for (long i = 0; i < RARRAY_LEN(members); i++) {
        VALUE slot = RARRAY_AREF(members, i);
        ID id = SYM2ID(slot);
        if (!(rb_is_local_id(id) || rb_is_const_id(id)) || !rb_enc_str_asciionly_p(rb_sym2str(slot))) return false;
    }
    return true;
}

// Whether inspecting the members of +s+ cannot come back to +s+, so that the
// recursion guard has nothing to guard: leaves, and structs of such members. A
// cycle would not end, so the depth limit turns it down.
static bool
inspect_struct_leaf_members_at_p(struct inspect_direct *direct, VALUE s, int depth)
{
    long len = RSTRUCT_LEN_RAW(s);
    for (long i = 0; i < len; i++) {
        VALUE value = RSTRUCT_GET_RAW(s, i);
        if (inspect_direct_cfunc(direct, value)) continue;
        if (depth < INSPECT_NESTED_DEPTH_MAX && !SPECIAL_CONST_P(value) && RB_TYPE_P(value, T_STRUCT) &&
            inspect_struct_nested_p(value) && inspect_struct_leaf_members_at_p(direct, value, depth + 1)) continue;
        return false;
    }
    return true;
}

static bool
inspect_struct_leaf_members_p(struct inspect_direct *direct, VALUE s)
{
    return inspect_struct_leaf_members_at_p(direct, s, 0);
}

// Writes what comes after the "#<struct" of +s+. +direct+ carries what
// inspect_struct_leaf_members_p() has already looked up.
static void
inspect_struct_write(struct inspect_bytes *out_ptr, VALUE s, int recur, struct inspect_direct *direct)
{
    VALUE cname = rb_class_path(rb_obj_class(s));
    VALUE members;
    VALUE str = out_ptr->str;
    rb_len_t i, len;
    char first = RSTRING_PTR(cname)[0];

    if (recur || first != '#') {
        inspect_bytes_cat(out_ptr, " ", 1);
        inspect_bytes_append(out_ptr, cname);
    }
    if (recur) {
        inspect_bytes_cat(out_ptr, ":...>", 5);
        return;
    }

    members = rb_struct_members(s);
    len = RSTRUCT_LEN_RAW(s);

    for (i=0; i<len; i++) {
        VALUE slot;
        ID id;

        if (i > 0) {
            inspect_bytes_cat(out_ptr, ", ", 2);
        }
        else {
            inspect_bytes_cat(out_ptr, " ", 1);
        }
        slot = RARRAY_AREF(members, i);
        id = SYM2ID(slot);
        if (rb_is_local_id(id) || rb_is_const_id(id)) {
            VALUE name = rb_sym2str(slot);
            if (rb_enc_str_asciionly_p(name) && rb_enc_asciicompat(rb_enc_get(str))) {
                // what rb_str_append() comes down to for ASCII text
                inspect_bytes_cat(out_ptr, RSTRING_PTR(name), RSTRING_LEN(name));
            }
            else {
                inspect_bytes_append(out_ptr, name);
            }
        }
        else {
            inspect_bytes_flush(out_ptr);
            rb_str_append(str, rb_inspect(slot));
        }
        inspect_bytes_cat(out_ptr, "=", 1);
        VALUE value = RSTRUCT_GET_RAW(s, i);
        const char *nested = !SPECIAL_CONST_P(value) && RB_TYPE_P(value, T_STRUCT) && !inspect_direct_cfunc(direct, value) && direct->nested ?
            inspect_struct_builtin_prefix(value) : NULL;
        if (nested) {
            inspect_bytes_cat(out_ptr, nested, (long)strlen(nested));
            inspect_struct_write(out_ptr, value, 0, direct);
        }
        else {
            inspect_struct_append_value(direct, out_ptr, value);
        }
    }
    inspect_bytes_cat(out_ptr, ">", 1);
}

static VALUE
inspect_struct_members(VALUE s, VALUE prefix, int recur, struct inspect_direct *direct)
{
    struct inspect_bytes out = { .str = prefix };
    inspect_struct_write(&out, s, recur, direct);
    inspect_bytes_flush(&out);
    return prefix;
}

static VALUE
inspect_struct(VALUE s, VALUE prefix, int recur)
{
    struct inspect_direct direct = {0};
    return inspect_struct_members(s, prefix, recur, &direct);
}

/*
 *  call-seq:
 *    inspect -> string
 *
 *  Returns a string representation of +self+:
 *
 *    Customer = Struct.new(:name, :address, :zip) # => Customer
 *    joe = Customer.new("Joe Smith", "123 Maple, Anytown NC", 12345)
 *    joe.inspect # => "#<struct Customer name=\"Joe Smith\", address=\"123 Maple, Anytown NC\", zip=12345>"
 *
 */

static VALUE
rb_struct_inspect(VALUE s)
{
    struct inspect_direct direct = {0};
    if (inspect_struct_leaf_members_p(&direct, s)) {
        direct.nested = true;
        return inspect_struct_members(s, inspect_struct_prefix(s, "#<struct"), 0, &direct);
    }
    return rb_exec_recursive(inspect_struct, s, inspect_struct_prefix(s, "#<struct"));
}

/*
 *  call-seq:
 *    to_a     -> array
 *
 *  Returns the values in +self+ as an array:
 *
 *    Customer = Struct.new(:name, :address, :zip)
 *    joe = Customer.new("Joe Smith", "123 Maple, Anytown NC", 12345)
 *    joe.to_a # => ["Joe Smith", "123 Maple, Anytown NC", 12345]
 *
 *  Related: #members.
 */

static VALUE
rb_struct_to_a(VALUE s)
{
    return rb_ary_new4(RSTRUCT_LEN_RAW(s), RSTRUCT_CONST_PTR(s));
}

/*
 *  call-seq:
 *    to_h -> hash
 *    to_h {|name, value| ... } -> hash
 *
 *  Returns a hash containing the name and value for each member:
 *
 *    Customer = Struct.new(:name, :address, :zip)
 *    joe = Customer.new("Joe Smith", "123 Maple, Anytown NC", 12345)
 *    h = joe.to_h
 *    h # => {name: "Joe Smith", address: "123 Maple, Anytown NC", zip: 12345}
 *
 *  If a block is given, it is called with each name/value pair;
 *  the block should return a 2-element array whose elements will become
 *  a key/value pair in the returned hash:
 *
 *    h = joe.to_h{|name, value| [name.upcase, value.to_s.upcase]}
 *    h # => {NAME: "JOE SMITH", ADDRESS: "123 MAPLE, ANYTOWN NC", ZIP: "12345"}
 *
 *  Raises ArgumentError if the block returns an inappropriate value.
 *
 */

static VALUE
struct_to_h_of(VALUE s, VALUE members, bool block_given)
{
    VALUE h = rb_hash_new_capa(RSTRUCT_LEN_RAW(s));
    rb_len_t i;

    if (!block_given) {
        // Member names are distinct Symbols, so the pairs can go in without
        // the per-key work of rb_hash_aset().
        rb_len_t len = RSTRUCT_LEN_RAW(s);
        if (rb_hash_fill_distinct_symbols(h, len, RARRAY_CONST_PTR(members), RSTRUCT_CONST_PTR(s))) {
            // Filling a big table may allocate memory; the pointers above must stay put
            RB_GC_GUARD(members);
            RB_GC_GUARD(s);
            return h;
        }
        VALUE buffer;
        VALUE *pairs = ALLOCV_N(VALUE, buffer, len * 2);
        for (i = 0; i < len; i++) {
            pairs[i * 2] = RARRAY_AREF(members, i);
            pairs[i * 2 + 1] = RSTRUCT_GET_RAW(s, i);
        }
        rb_hash_bulk_insert(len * 2, pairs, h);
        ALLOCV_END(buffer);
        return h;
    }

    for (i=0; i<RSTRUCT_LEN_RAW(s); i++) {
        VALUE k = rb_ary_entry(members, i), v = RSTRUCT_GET_RAW(s, i);
        rb_hash_set_pair(h, rb_yield_values(2, k, v));
    }
    return h;
}

static VALUE
struct_to_h(VALUE s, bool block_given)
{
    return struct_to_h_of(s, rb_struct_members(s), block_given);
}

static VALUE
rb_struct_to_h(VALUE s)
{
    return struct_to_h(s, rb_block_given_p());
}

/*
 *  call-seq:
 *    deconstruct_keys(array_of_names) -> hash
 *
 *  Returns a hash of the name/value pairs for the given member names.
 *
 *    Customer = Struct.new(:name, :address, :zip)
 *    joe = Customer.new("Joe Smith", "123 Maple, Anytown NC", 12345)
 *    h = joe.deconstruct_keys([:zip, :address])
 *    h # => {zip: 12345, address: "123 Maple, Anytown NC"}
 *
 *  Returns all names and values if +array_of_names+ is +nil+:
 *
 *    h = joe.deconstruct_keys(nil)
 *    h # => {name: "Joseph Smith, Jr.", address: "123 Maple, Anytown NC", zip: 12345}
 *
 */
static VALUE
rb_struct_deconstruct_keys(VALUE s, VALUE keys)
{
    return deconstruct_keys(s, keys, false, rb_block_given_p());
}

#define DECONSTRUCT_SYMBOL_KEYS_MAX 8

// What a pattern like `in {x:, y:}` asks for: a few Symbols, none given twice. Finding the
// members runs no Ruby code, and such pairs can go into the empty +h+ without the per-key
// work of rb_hash_aset(), like the ones of to_h. Returns false, with +h+ still empty, for
// any other list of keys.
static bool
deconstruct_symbol_keys(VALUE s, VALUE keys, VALUE h)
{
    long len = RARRAY_LEN(keys), n;
    if (len > DECONSTRUCT_SYMBOL_KEYS_MAX) return false;

    VALUE names[DECONSTRUCT_SYMBOL_KEYS_MAX], values[DECONSTRUCT_SYMBOL_KEYS_MAX];
    VALUE back = 0;
    for (n = 0; n < len; n++) {
        VALUE key = RARRAY_AREF(keys, n);
        if (!SYMBOL_P(key)) return false;
        for (long seen = 0; seen < n; seen++) {
            if (names[seen] == key) return false;
        }
        int pos = struct_pos_cached(s, &key, false, &back);
        if (pos < 0) break; // the Hash ends before the first name that is not a member
        names[n] = key;
        values[n] = RSTRUCT_GET_RAW(s, pos);
    }
    return rb_hash_fill_distinct_symbols(h, n, names, values);
}

static VALUE
deconstruct_keys(VALUE s, VALUE keys, bool name_only, bool block_given)
{
    VALUE h;
    rb_len_t i;

    if (NIL_P(keys)) {
        return struct_to_h(s, block_given);
    }
    if (UNLIKELY(!RB_TYPE_P(keys, T_ARRAY))) {
        rb_raise(rb_eTypeError,
                 "wrong argument type %"PRIsVALUE" (expected Array or nil)",
                 rb_obj_class(keys));

    }
    if (RSTRUCT_LEN_RAW(s) < RARRAY_LEN(keys)) {
        return rb_hash_new();
    }
    h = rb_hash_new_capa(RARRAY_LEN(keys));
    if (deconstruct_symbol_keys(s, keys, h)) {
        return h;
    }
    VALUE back = 0;
    for (i=0; i<RARRAY_LEN(keys); i++) {
        VALUE key = RARRAY_AREF(keys, i);
        int i = struct_pos_cached(s, &key, name_only, &back);
        if (i < 0) {
            return h;
        }
        rb_hash_aset(h, key, RSTRUCT_GET_RAW(s, i));
    }
    return h;
}

/* :nodoc: */
VALUE
rb_struct_init_copy(VALUE copy, VALUE s)
{
    rb_len_t i, len;

    if (!OBJ_INIT_COPY(copy, s)) return copy;
    if (RSTRUCT_LEN_RAW(copy) != RSTRUCT_LEN_RAW(s)) {
        rb_raise(rb_eTypeError, "struct size mismatch");
    }

    for (i=0, len=RSTRUCT_LEN_RAW(copy); i<len; i++) {
        RSTRUCT_SET_RAW(copy, i, RSTRUCT_GET_RAW(s, i));
    }

    return copy;
}

// +back+ caches __back_members__ across calls for the same struct; start it at 0.
// It is filled on first use so that errors are raised at the same point as before.
static int
struct_pos_cached(VALUE s, VALUE *name, bool name_only, VALUE *back)
{
    rb_len_t i;
    VALUE idx = *name;

    if (!SYMBOL_P(idx) && (name_only || RB_TYPE_P(idx, T_STRING))) {
        idx = rb_check_symbol(name);
        if (NIL_P(idx)) return -1;
    }
    if (SYMBOL_P(idx)) {
        if (!*back) *back = struct_ivar_get(rb_obj_class(s), id_back_members);
        return struct_member_pos_in(s, idx, *back);
    }
    else {
        rb_len_t len;
        i = NUM2LEN(idx);
        len = RSTRUCT_LEN_RAW(s);
        if (i < 0) {
            if (i + len < 0) {
                *name = LEN2NUM(i);
                return -1;
            }
            i += len;
        }
        else if (len <= i) {
            *name = LEN2NUM(i);
            return -1;
        }
        return (int)i;
    }
}

static int
rb_struct_pos(VALUE s, VALUE *name, bool name_only)
{
    VALUE back = 0;
    return struct_pos_cached(s, name, name_only, &back);
}

static void
invalid_struct_pos(VALUE s, VALUE idx)
{
    if (RB_INTEGER_TYPE_P(idx)) {
        rb_len_t i = NUM2LEN(idx), len = RSTRUCT_LEN_RAW(s);
        if (i < 0) {
            rb_raise(rb_eIndexError, "offset %"PRIdLEN" too small for struct(size:%"PRIdLEN")",
                     i, len);
        }
        else {
            rb_raise(rb_eIndexError, "offset %"PRIdLEN" too large for struct(size:%"PRIdLEN")",
                     i, len);
        }
    }
    else {
        rb_name_err_raise("no member '%1$s' in struct", s, idx);
    }
}

/*
 *  call-seq:
 *    struct[name] -> object
 *    struct[n] -> object
 *
 *  Returns a value from +self+.
 *
 *  With symbol or string argument +name+ given, returns the value for the named member:
 *
 *    Customer = Struct.new(:name, :address, :zip)
 *    joe = Customer.new("Joe Smith", "123 Maple, Anytown NC", 12345)
 *    joe[:zip] # => 12345
 *
 *  Raises NameError if +name+ is not the name of a member.
 *
 *  With integer argument +n+ given, returns <tt>self.values[n]</tt>
 *  if +n+ is in range;
 *  see Array@Array+Indexes:
 *
 *    joe[2]  # => 12345
 *    joe[-2] # => "123 Maple, Anytown NC"
 *
 *  Raises IndexError if +n+ is out of range.
 *
 */

VALUE
rb_struct_aref(VALUE s, VALUE idx)
{
    int i = rb_struct_pos(s, &idx, false);
    if (i < 0) invalid_struct_pos(s, idx);
    return RSTRUCT_GET_RAW(s, i);
}

/*
 *  call-seq:
 *    struct[name] = value -> value
 *    struct[n] = value -> value
 *
 *  Assigns a value to a member.
 *
 *  With symbol or string argument +name+ given, assigns the given +value+
 *  to the named member; returns +value+:
 *
 *    Customer = Struct.new(:name, :address, :zip)
 *    joe = Customer.new("Joe Smith", "123 Maple, Anytown NC", 12345)
 *    joe[:zip] = 54321 # => 54321
 *    joe # => #<struct Customer name="Joe Smith", address="123 Maple, Anytown NC", zip=54321>
 *
 *  Raises NameError if +name+ is not the name of a member.
 *
 *  With integer argument +n+ given, assigns the given +value+
 *  to the +n+-th member if +n+ is in range;
 *  see Array@Array+Indexes:
 *
 *    joe = Customer.new("Joe Smith", "123 Maple, Anytown NC", 12345)
 *    joe[2] = 54321           # => 54321
 *    joe[-3] = 'Joseph Smith' # => "Joseph Smith"
 *    joe # => #<struct Customer name="Joseph Smith", address="123 Maple, Anytown NC", zip=54321>
 *
 *  Raises IndexError if +n+ is out of range.
 *
 */

VALUE
rb_struct_aset(VALUE s, VALUE idx, VALUE val)
{
    int i = rb_struct_pos(s, &idx, false);
    if (i < 0) invalid_struct_pos(s, idx);
    rb_struct_modify(s);
    RSTRUCT_SET_RAW(s, i, val);
    return val;
}

FUNC_MINIMIZED(VALUE rb_struct_lookup(VALUE s, VALUE idx));
NOINLINE(static VALUE rb_struct_lookup_default(VALUE s, VALUE idx, VALUE notfound, bool name_only));

VALUE
rb_struct_lookup(VALUE s, VALUE idx)
{
    return rb_struct_lookup_default(s, idx, Qnil, false);
}

static VALUE
rb_struct_lookup_default(VALUE s, VALUE idx, VALUE notfound, bool name_only)
{
    int i = rb_struct_pos(s, &idx, name_only);
    if (i < 0) return notfound;
    return RSTRUCT_GET_RAW(s, i);
}

static VALUE
struct_entry(VALUE s, rb_len_t n)
{
    return rb_struct_aref(s, LEN2NUM(n));
}

/*
 *  call-seq:
 *    values_at(*integers) -> array
 *    values_at(integer_range) -> array
 *
 *  Returns an array of values from +self+.
 *
 *  With integer arguments +integers+ given,
 *  returns an array containing each value given by one of +integers+:
 *
 *    Customer = Struct.new(:name, :address, :zip)
 *    joe = Customer.new("Joe Smith", "123 Maple, Anytown NC", 12345)
 *    joe.values_at(0, 2)    # => ["Joe Smith", 12345]
 *    joe.values_at(2, 0)    # => [12345, "Joe Smith"]
 *    joe.values_at(2, 1, 0) # => [12345, "123 Maple, Anytown NC", "Joe Smith"]
 *    joe.values_at(0, -3)   # => ["Joe Smith", "Joe Smith"]
 *
 *  Raises IndexError if any of +integers+ is out of range;
 *  see Array@Array+Indexes.
 *
 *  With integer range argument +integer_range+ given,
 *  returns an array containing each value given by the elements of the range;
 *  fills with +nil+ values for range elements larger than the structure:
 *
 *    joe.values_at(0..2)
 *    # => ["Joe Smith", "123 Maple, Anytown NC", 12345]
 *    joe.values_at(-3..-1)
 *    # => ["Joe Smith", "123 Maple, Anytown NC", 12345]
 *    joe.values_at(1..4) # => ["123 Maple, Anytown NC", 12345, nil, nil]
 *
 *  Raises RangeError if any element of the range is negative and out of range;
 *  see Array@Array+Indexes.
 *
 */

static VALUE
rb_struct_values_at(int argc, VALUE *argv, VALUE s)
{
    return rb_get_values_at(s, RSTRUCT_LEN_RAW(s), argc, argv, struct_entry);
}

/*
 *  call-seq:
 *    select {|value| ... } -> array
 *    select -> enumerator
 *
 *  With a block given, returns an array of values from +self+
 *  for which the block returns a truthy value:
 *
 *    Customer = Struct.new(:name, :address, :zip)
 *    joe = Customer.new("Joe Smith", "123 Maple, Anytown NC", 12345)
 *    a = joe.select {|value| value.is_a?(String) }
 *    a # => ["Joe Smith", "123 Maple, Anytown NC"]
 *    a = joe.select {|value| value.is_a?(Integer) }
 *    a # => [12345]
 *
 *  With no block given, returns an Enumerator.
 */

static VALUE
rb_struct_select(int argc, VALUE *argv, VALUE s)
{
    VALUE result;
    rb_len_t i;

    rb_check_arity(argc, 0, 0);
    RETURN_SIZED_ENUMERATOR(s, 0, 0, struct_enum_size);
    result = rb_ary_new();
    for (i = 0; i < RSTRUCT_LEN_RAW(s); i++) {
        if (RTEST(rb_yield(RSTRUCT_GET_RAW(s, i)))) {
            rb_ary_push(result, RSTRUCT_GET_RAW(s, i));
        }
    }

    return result;
}

// Compares the members as far as that needs no method call: Qtrue, Qfalse, or
// Qundef when a call would be needed. Without a call nothing can re-enter the
// comparison, so the recursion guard has nothing to catch. It answers Qtrue
// both for equal structs and for a pair that is already being compared, so
// Qtrue stands as is; Qfalse only stands when no comparison of the same pair
// is in progress further up the stack, where it would compare as Qtrue.
//
// Such a comparison went through the members in the same order and got past
// the pair that differs here, so that pair has changed since. That cannot
// happen when both are Data, whose members never change, and both values are
// frozen (Integer, Symbol, Float, frozen String), which saves looking the guard up.
static inline bool
struct_equal_immutable_p(VALUE v)
{
    return SPECIAL_CONST_P(v) || OBJ_FROZEN_RAW(v);
}

// Whether +s+ is a Data. Its members are fixed from the moment it exists, which
// a frozen Struct cannot promise: a method called in the middle of comparing or
// hashing it may have changed its members and frozen it.
bool
rb_struct_data_p(VALUE s)
{
    return RTEST(rb_obj_is_kind_of(s, rb_cData));
}

static VALUE
struct_equal_without_call(VALUE s, VALUE s2, VALUE (*opt_equal)(VALUE, VALUE))
{
    long len = RSTRUCT_LEN_RAW(s);
    const VALUE *ptr = RSTRUCT_CONST_PTR(s), *ptr2 = RSTRUCT_CONST_PTR(s2);
    // The caller has checked both are of the same class
    bool frozen = rb_struct_data_p(s);
    for (long i = 0; i < len; i++) {
        VALUE v = ptr[i], v2 = ptr2[i];
        if (v == v2) continue;

        VALUE result = opt_equal(v, v2);
        if (UNDEF_P(result)) return Qundef;
        if (!RTEST(result)) {
            if (frozen && struct_equal_immutable_p(v) && struct_equal_immutable_p(v2)) return Qfalse;
            return Qundef;
        }
    }
    return Qtrue;
}

static VALUE
recursive_equal(VALUE s, VALUE s2, int recur)
{
    rb_len_t i, len;

    if (recur) return Qtrue; /* Subtle! */
    len = RSTRUCT_LEN_RAW(s);
    for (i=0; i<len; i++) {
        if (!rb_equal(RSTRUCT_GET_RAW(s, i), RSTRUCT_GET_RAW(s2, i))) return Qfalse;
    }
    return Qtrue;
}


/*
 *  call-seq:
 *    self == other -> true or false
 *
 *  Returns whether both the following are true:
 *
 *  - <tt>other.class == self.class</tt>.
 *  - For each member name +name+, <tt>other.name == self.name</tt>.
 *
 *  Examples:
 *
 *    Customer = Struct.new(:name, :address, :zip)
 *    joe    = Customer.new("Joe Smith", "123 Maple, Anytown NC", 12345)
 *    joe_jr = Customer.new("Joe Smith", "123 Maple, Anytown NC", 12345)
 *    joe_jr == joe # => true
 *    joe_jr[:name] = 'Joe Smith, Jr.'
 *    # => "Joe Smith, Jr."
 *    joe_jr == joe # => false
 */

static VALUE
rb_struct_equal(VALUE s, VALUE s2)
{
    if (s == s2) return Qtrue;
    if (!RB_TYPE_P(s2, T_STRUCT)) return Qfalse;
    // Instances without a singleton class mostly: the same klass is the same class
    if (RBASIC_CLASS(s) != RBASIC_CLASS(s2) && rb_obj_class(s) != rb_obj_class(s2)) return Qfalse;
    if (RSTRUCT_LEN_RAW(s) != RSTRUCT_LEN_RAW(s2)) {
        rb_bug("inconsistent struct"); /* should never happen */
    }

    VALUE result = struct_equal_without_call(s, s2, rb_equal_opt);
    if (!UNDEF_P(result)) return result;

    return rb_exec_recursive_paired(recursive_equal, s, s2, s2);
}

/*
 *  call-seq:
 *    hash -> integer
 *
 *  Returns the integer hash value for +self+.
 *
 *  Two structs of the same class and with the same content
 *  will have the same hash code (and will compare using Struct#eql?):
 *
 *    Customer = Struct.new(:name, :address, :zip)
 *    joe    = Customer.new("Joe Smith", "123 Maple, Anytown NC", 12345)
 *    joe_jr = Customer.new("Joe Smith", "123 Maple, Anytown NC", 12345)
 *    joe.hash == joe_jr.hash # => true
 *    joe_jr[:name] = 'Joe Smith, Jr.'
 *    joe.hash == joe_jr.hash # => false
 *
 *  Related: Object#hash.
 */

// The hash of +s+, starting from +class_hash+: what rb_hash() makes of its class
static VALUE
struct_hash(VALUE s, VALUE class_hash)
{
    rb_len_t i, len;
    st_index_t h;
    VALUE n;

    h = rb_hash_start(class_hash);
    len = RSTRUCT_LEN_RAW(s);
    for (i = 0; i < len; i++) {
        n = rb_hash(RSTRUCT_GET_RAW(s, i));
        h = rb_hash_uint(h, NUM2LONG(n));
    }
    h = rb_hash_end(h);
    return ST2FIX(h);
}

VALUE
rb_struct_hash(VALUE s)
{
    return struct_hash(s, rb_hash(rb_obj_class(s)));
}

VALUE rb_obj_hash(VALUE obj);

// Struct#hash for hash.c, which found the hash of the class to be Kernel#hash:
// what rb_hash() would call, without looking the method up again
VALUE
rb_struct_hash_of_basic_class(VALUE s)
{
    return struct_hash(s, rb_obj_hash(rb_obj_class(s)));
}

static VALUE
recursive_eql(VALUE s, VALUE s2, int recur)
{
    rb_len_t i, len;

    if (recur) return Qtrue; /* Subtle! */
    len = RSTRUCT_LEN_RAW(s);
    for (i=0; i<len; i++) {
        if (!rb_eql(RSTRUCT_GET_RAW(s, i), RSTRUCT_GET_RAW(s2, i))) return Qfalse;
    }
    return Qtrue;
}

/*
 * call-seq:
 *   eql?(other) -> true or false
 *
 *  Returns +true+ if and only if the following are true; otherwise returns +false+:
 *
 *  - <tt>other.class == self.class</tt>.
 *  - For each member name +name+, <tt>other.name.eql?(self.name)</tt>.
 *
 *     Customer = Struct.new(:name, :address, :zip)
 *     joe    = Customer.new("Joe Smith", "123 Maple, Anytown NC", 12345)
 *     joe_jr = Customer.new("Joe Smith", "123 Maple, Anytown NC", 12345)
 *     joe_jr.eql?(joe) # => true
 *     joe_jr[:name] = 'Joe Smith, Jr.'
 *     joe_jr.eql?(joe) # => false
 *
 *  Related: Object#==.
 */

static VALUE
rb_struct_eql(VALUE s, VALUE s2)
{
    if (s == s2) return Qtrue;
    if (!RB_TYPE_P(s2, T_STRUCT)) return Qfalse;
    // Instances without a singleton class mostly: the same klass is the same class
    if (RBASIC_CLASS(s) != RBASIC_CLASS(s2) && rb_obj_class(s) != rb_obj_class(s2)) return Qfalse;
    if (RSTRUCT_LEN_RAW(s) != RSTRUCT_LEN_RAW(s2)) {
        rb_bug("inconsistent struct"); /* should never happen */
    }

    VALUE result = struct_equal_without_call(s, s2, rb_eql_opt);
    if (!UNDEF_P(result)) return result;

    return rb_exec_recursive_paired(recursive_eql, s, s2, s2);
}

// eql? of +s+ and +s2+ for a Hash matching +s+ against a key: Qtrue or Qfalse when the
// Struct#eql? +s+ has settles it without calling a method, Qundef when it is not that
// method, or would call one, or a TracePoint is watching C calls. The Hash then calls
// eql? as it did, with its frame.
VALUE
rb_struct_eql_without_call(VALUE s, VALUE s2)
{
    if (ruby_vm_c_events_enabled > 0) return Qundef;
    const rb_callable_method_entry_t *cme = rb_callable_method_entry(CLASS_OF(s), idEqlP);
    if (!cme || cme->def->type != VM_METHOD_TYPE_CFUNC || cme->def->body.cfunc.func != (rb_cfunc_t)rb_struct_eql) {
        return Qundef;
    }
    if (!RB_TYPE_P(s2, T_STRUCT)) return Qfalse;
    if (RBASIC_CLASS(s) != RBASIC_CLASS(s2) && rb_obj_class(s) != rb_obj_class(s2)) return Qfalse;
    return struct_equal_without_call(s, s2, rb_eql_opt);
}

/*
 *  call-seq:
 *    size -> integer
 *
 *  Returns the number of members.
 *
 *    Customer = Struct.new(:name, :address, :zip)
 *    joe = Customer.new("Joe Smith", "123 Maple, Anytown NC", 12345)
 *    joe.size #=> 3
 *
 */

VALUE
rb_struct_size(VALUE s)
{
    return LEN2NUM(RSTRUCT_LEN_RAW(s));
}

/*
 * call-seq:
 *   dig(name, *identifiers) -> object
 *   dig(n, *identifiers) -> object
 *
 *  Finds and returns an object among nested objects.
 *  The nested objects may be instances of various classes.
 *  See {Dig Methods}[rdoc-ref:dig_methods.rdoc].
 *
 *
 *  Given symbol or string argument +name+,
 *  returns the object that is specified by +name+ and +identifiers+:
 *
 *   Foo = Struct.new(:a)
 *   f = Foo.new(Foo.new({b: [1, 2, 3]}))
 *   f.dig(:a) # => #<struct Foo a={b: [1, 2, 3]}>
 *   f.dig(:a, :a) # => {b: [1, 2, 3]}
 *   f.dig(:a, :a, :b) # => [1, 2, 3]
 *   f.dig(:a, :a, :b, 0) # => 1
 *   f.dig(:b, 0) # => nil
 *
 *  Given integer argument +n+,
 *  returns the object that is specified by +n+ and +identifiers+:
 *
 *   f.dig(0) # => #<struct Foo a={b: [1, 2, 3]}>
 *   f.dig(0, 0) # => {b: [1, 2, 3]}
 *   f.dig(0, 0, :b) # => [1, 2, 3]
 *   f.dig(0, 0, :b, 0) # => 1
 *   f.dig(:b, 0) # => nil
 *
 */

static VALUE
rb_struct_dig(int argc, VALUE *argv, VALUE self)
{
    rb_check_arity(argc, 1, UNLIMITED_ARGUMENTS);
    self = rb_struct_lookup(self, *argv);
    if (!--argc) return self;
    ++argv;
    return rb_obj_dig(argc, argv, self, Qnil);
}

/*
 *  Document-class: Data
 *
 *  Class \Data provides a convenient way to define simple classes
 *  for value-alike objects.
 *
 *  The simplest example of usage:
 *
 *     Measure = Data.define(:amount, :unit)
 *
 *     # Positional arguments constructor is provided
 *     distance = Measure.new(100, 'km')
 *     #=> #<data Measure amount=100, unit="km">
 *
 *     # Keyword arguments constructor is provided
 *     weight = Measure.new(amount: 50, unit: 'kg')
 *     #=> #<data Measure amount=50, unit="kg">
 *
 *     # Alternative form to construct an object:
 *     speed = Measure[10, 'mPh']
 *     #=> #<data Measure amount=10, unit="mPh">
 *
 *     # Works with keyword arguments, too:
 *     area = Measure[amount: 1.5, unit: 'm^2']
 *     #=> #<data Measure amount=1.5, unit="m^2">
 *
 *     # Argument accessors are provided:
 *     distance.amount #=> 100
 *     distance.unit #=> "km"
 *
 *  Constructed object also has a reasonable definitions of #==
 *  operator, #to_h hash conversion, and #deconstruct / #deconstruct_keys
 *  to be used in pattern matching.
 *
 *  ::define method accepts an optional block and evaluates it in
 *  the context of the newly defined class. That allows to define
 *  additional methods:
 *
 *     Measure = Data.define(:amount, :unit) do
 *       def <=>(other)
 *         return unless other.is_a?(self.class) && other.unit == unit
 *         amount <=> other.amount
 *       end
 *
 *       include Comparable
 *     end
 *
 *     Measure[3, 'm'] < Measure[5, 'm'] #=> true
 *     Measure[3, 'm'] < Measure[5, 'kg']
 *     # comparison of Measure with Measure failed (ArgumentError)
 *
 *  Data provides no member writers, or enumerators: it is meant
 *  to be a storage for immutable atomic values. But note that
 *  if some of data members is of a mutable class, Data does no additional
 *  immutability enforcement:
 *
 *     Event = Data.define(:time, :weekdays)
 *     event = Event.new('18:00', %w[Tue Wed Fri])
 *     #=> #<data Event time="18:00", weekdays=["Tue", "Wed", "Fri"]>
 *
 *     # There is no #time= or #weekdays= accessors, but changes are
 *     # still possible:
 *     event.weekdays << 'Sat'
 *     event
 *     #=> #<data Event time="18:00", weekdays=["Tue", "Wed", "Fri", "Sat"]>
 *
 *  See also Struct, which is a similar concept, but has more
 *  container-alike API, allowing to change contents of the object
 *  and enumerate it.
 */

/*
 * call-seq:
 *   define(*symbols) -> class
 *
 *  Defines a new \Data class.
 *
 *     measure = Data.define(:amount, :unit)
 *     #=> #<Class:0x00007f70c6868498>
 *     measure.new(1, 'km')
 *     #=> #<data amount=1, unit="km">
 *
 *     # It you store the new class in the constant, it will
 *     # affect #inspect and will be more natural to use:
 *     Measure = Data.define(:amount, :unit)
 *     #=> Measure
 *     Measure.new(1, 'km')
 *     #=> #<data Measure amount=1, unit="km">
 *
 *
 *  Note that member-less \Data is acceptable and might be a useful technique
 *  for defining several homogeneous data classes, like
 *
 *     class HTTPFetcher
 *       Response = Data.define(:body)
 *       NotFound = Data.define
 *       # ... implementation
 *     end
 *
 *  Now, different kinds of responses from +HTTPFetcher+ would have consistent
 *  representation:
 *
 *      #<data HTTPFetcher::Response body="<html...">
 *      #<data HTTPFetcher::NotFound>
 *
 *  And are convenient to use in pattern matching:
 *
 *     case fetcher.get(url)
 *     in HTTPFetcher::Response(body)
 *       # process body variable
 *     in HTTPFetcher::NotFound
 *       # handle not found case
 *     end
 */

static VALUE
rb_data_s_def(int argc, VALUE *argv, VALUE klass)
{
    VALUE rest;
    rb_len_t i;
    VALUE data_class;

    rest = rb_ident_hash_new();
    RBASIC_CLEAR_CLASS(rest);
    for (i=0; i<argc; i++) {
        VALUE mem = rb_to_symbol(argv[i]);
        if (rb_is_attrset_sym(mem)) {
            rb_raise(rb_eArgError, "invalid data member: %"PRIsVALUE, mem);
        }
        if (RTEST(rb_hash_has_key(rest, mem))) {
            rb_raise(rb_eArgError, "duplicate member: %"PRIsVALUE, mem);
        }
        rb_hash_aset(rest, mem, Qtrue);
    }
    rest = rb_hash_keys(rest);
    RBASIC_CLEAR_CLASS(rest);
    OBJ_FREEZE(rest);
    data_class = anonymous_struct(klass);
    setup_data(data_class, rest);
    if (rb_block_given_p()) {
        rb_mod_module_eval(0, 0, data_class);
    }

    return data_class;
}

VALUE
rb_data_define(VALUE super, ...)
{
    va_list ar;
    VALUE ary;
    va_start(ar, super);
    ary = struct_make_members_list(ar);
    va_end(ar);
    if (!super) super = rb_cData;
    VALUE klass = setup_data(anonymous_struct(super), ary);
    rb_vm_register_global_object(klass);
    return klass;
}

static int
data_hash_set_i(VALUE key, VALUE val, VALUE arg)
{
    struct struct_hash_set_arg *args = (struct struct_hash_set_arg *)arg;
    int i = struct_hash_aset(key, val, args, true);
    if (i >= 0 && !args->found[i]) {
        args->found[i] = 1;
        args->missing_count--;
    }
    return ST_CONTINUE;
}

/*
 *  call-seq:
 *    DataClass::members -> array_of_symbols
 *
 *  Returns an array of member names of the data class:
 *
 *     Measure = Data.define(:amount, :unit)
 *     Measure.members # => [:amount, :unit]
 *
 */

#define rb_data_s_members_m rb_struct_s_members_m


/*
 * call-seq:
 *   new(*args) -> instance
 *   new(**kwargs) -> instance
 *   ::[](*args) -> instance
 *   ::[](**kwargs) -> instance
 *
 *  Constructors for classes defined with ::define accept both positional and
 *  keyword arguments.
 *
 *     Measure = Data.define(:amount, :unit)
 *
 *     Measure.new(1, 'km')
 *     #=> #<data Measure amount=1, unit="km">
 *     Measure.new(amount: 1, unit: 'km')
 *     #=> #<data Measure amount=1, unit="km">
 *
 *     # Alternative shorter initialization with []
 *     Measure[1, 'km']
 *     #=> #<data Measure amount=1, unit="km">
 *     Measure[amount: 1, unit: 'km']
 *     #=> #<data Measure amount=1, unit="km">
 *
 *  All arguments are mandatory (unlike Struct), and converted to keyword arguments:
 *
 *     Measure.new(amount: 1)
 *     # in `initialize': missing keyword: :unit (ArgumentError)
 *
 *     Measure.new(1)
 *     # in `initialize': missing keyword: :unit (ArgumentError)
 *
 *  Note that <tt>Measure#initialize</tt> always receives keyword arguments, and that
 *  mandatory arguments are checked in +initialize+, not in +new+. This can be
 *  important for redefining initialize in order to convert arguments or provide
 *  defaults:
 *
 *     Measure = Data.define(:amount, :unit)
 *     class Measure
 *       NONE = Data.define
 *
 *       def initialize(amount:, unit: NONE.new)
 *         super(amount: Float(amount), unit:)
 *       end
 *     end
 *
 *     Measure.new('10', 'km') # => #<data Measure amount=10.0, unit="km">
 *     Measure.new(10_000)     # => #<data Measure amount=10000.0, unit=#<data Measure::NONE>>
 *
 */

static VALUE
rb_data_initialize_m(int argc, const VALUE *argv, VALUE self)
{
    VALUE klass = rb_obj_class(self);
    rb_struct_modify(self);
    long num_members = RSTRUCT_LEN_RAW(self);

    if (argc == 0) {
        if (num_members > 0) {
            rb_exc_raise(rb_keyword_error_new("missing", struct_ivar_get(klass, id_members)));
        }
        OBJ_FREEZE(self);
        return Qnil;
    }
    if (argc > 1 || !RB_TYPE_P(argv[0], T_HASH)) {
        rb_error_arity(argc, 0, 0);
    }

    struct keyword_positions kw;
    if (resolve_keyword_positions(klass, num_members, argv[0], &kw) && kw.count == num_members) {
        // Distinct Symbols, as many as there are members: none is missing.
        for (int i = 0; i < kw.count; i++) {
            RSTRUCT_SET_RAW(self, kw.positions[i], kw.values[i]);
        }
        OBJ_FREEZE(self);
        return Qnil;
    }

    VALUE found_buffer;
    char *found = ALLOCV_N(char, found_buffer, num_members);
    MEMZERO(found, char, num_members);
    struct struct_hash_set_arg arg = {
        .self = self,
        .unknown_keywords = Qnil,
        .found = found,
        .missing_count = num_members,
    };
    rb_mem_clear((VALUE *)RSTRUCT_CONST_PTR(self), num_members);
    rb_hash_foreach(argv[0], data_hash_set_i, (VALUE)&arg);
    // Freeze early before potentially raising, so that we don't leave an
    // unfrozen copy on the heap, which could get exposed via ObjectSpace.
    OBJ_FREEZE(self);
    if (UNLIKELY(arg.missing_count > 0)) {
        VALUE members = struct_ivar_get(klass, id_members);
        VALUE missing = rb_ary_new_capa(arg.missing_count);
        for (rb_len_t i = 0; i < num_members; i++) {
            if (!found[i]) rb_ary_push(missing, RARRAY_AREF(members, i));
        }
        rb_exc_raise(rb_keyword_error_new("missing", missing));
    }
    ALLOCV_END(found_buffer);
    VALUE unknown_keywords = arg.unknown_keywords;
    if (UNLIKELY(!NIL_P(unknown_keywords))) {
        RBASIC_SET_CLASS_RAW(unknown_keywords, rb_cArray);
        rb_exc_raise(rb_keyword_error_new("unknown", unknown_keywords));
    }

    return Qnil;
}

/* :nodoc: */
static VALUE
rb_data_init_copy(VALUE copy, VALUE s)
{
    copy = rb_struct_init_copy(copy, s);
    RB_OBJ_FREEZE(copy);
    return copy;
}

/*
 *  call-seq:
 *   with(**kwargs) -> instance
 *
 *  Returns a shallow copy of +self+ --- the instance variables of
 *  +self+ are copied, but not the objects they reference.
 *
 *  If the method is supplied any keyword arguments, the copy will
 *  be created with the respective field values updated to use the
 *  supplied keyword argument values. Note that it is an error to
 *  supply a keyword that the Data class does not have as a member.
 *
 *    Point = Data.define(:x, :y)
 *
 *    origin = Point.new(x: 0, y: 0)
 *
 *    up = origin.with(x: 1)
 *    right = origin.with(y: 1)
 *    up_and_right = up.with(y: 1)
 *
 *    p origin       # #<data Point x=0, y=0>
 *    p up           # #<data Point x=1, y=0>
 *    p right        # #<data Point x=0, y=1>
 *    p up_and_right # #<data Point x=1, y=1>
 *
 *    out = origin.with(z: 1) # ArgumentError: unknown keyword: :z
 *    some_point = origin.with(1, 2) # ArgumentError: expected keyword arguments, got positional arguments
 *
 */

// A copy of +self+ with +kwargs+ applied, made without going through
// initialize; Qundef when that could be told apart from calling it.
// Every keyword is resolved before allocating: see rb_data_initialize_m()
// about not leaving an unfrozen instance on the heap.
static VALUE
data_with_direct(VALUE self, VALUE kwargs)
{
    VALUE klass = rb_obj_class(self);
    if (!data_initialize_unobservable_p(klass)) return Qundef;

    struct keyword_positions arg;
    if (!resolve_keyword_positions(klass, RSTRUCT_LEN_RAW(self), kwargs, &arg)) return Qundef;

    long n = RSTRUCT_LEN_RAW(self);
    VALUE copy = rb_obj_alloc(klass);
    if (!RB_TYPE_P(copy, T_STRUCT) || RSTRUCT_LEN_RAW(copy) != n || OBJ_FROZEN(copy)) {
        VALUE h = rb_struct_to_h(self);
        rb_hash_update_by(h, kwargs, 0);
        rb_obj_call_init_kw(copy, 1, &h, RB_PASS_KEYWORDS);
        return copy;
    }

    for (long i = 0; i < n; i++) {
        RSTRUCT_SET_RAW(copy, i, RSTRUCT_GET_RAW(self, i));
    }
    for (int i = 0; i < arg.count; i++) {
        RSTRUCT_SET_RAW(copy, arg.positions[i], arg.values[i]);
    }
    OBJ_FREEZE(copy);
    return copy;
}

static VALUE
rb_data_with(int argc, const VALUE *argv, VALUE self)
{
    VALUE kwargs;
    if (argc == 1 && rb_keyword_given_p()) {
        // What rb_scan_args(argc, argv, "0:", &kwargs) settles on, without the copy it makes
        // of the Hash: it is only read from here on.
        kwargs = argv[0];
    }
    else {
        rb_scan_args(argc, argv, "0:", &kwargs);
        if (NIL_P(kwargs)) {
            return self;
        }
    }

    // The regular path hands a block on to to_h, which then wants pairs from it
    VALUE copy = rb_block_given_p() ? Qundef : data_with_direct(self, kwargs);
    if (!UNDEF_P(copy)) return copy;

    VALUE h = rb_struct_to_h(self);
    rb_hash_update_by(h, kwargs, 0);
    return rb_class_new_instance_kw(1, &h, rb_obj_class(self), TRUE);
}

/*
 *  call-seq:
 *    inspect -> string
 *    to_s -> string
 *
 *  Returns a string representation of +self+:
 *
 *    Measure = Data.define(:amount, :unit)
 *
 *    distance = Measure[10, 'km']
 *
 *    p distance  # uses #inspect underneath
 *    #<data Measure amount=10, unit="km">
 *
 *    puts distance  # uses #to_s underneath, same representation
 *    #<data Measure amount=10, unit="km">
 *
 */

static VALUE
rb_data_inspect(VALUE s)
{
    struct inspect_direct direct = {0};
    if (inspect_struct_leaf_members_p(&direct, s)) {
        direct.nested = true;
        return inspect_struct_members(s, inspect_struct_prefix(s, "#<data"), 0, &direct);
    }
    return rb_exec_recursive(inspect_struct, s, inspect_struct_prefix(s, "#<data"));
}

/*
 *  call-seq:
 *    self == other -> true or false
 *
 *  Returns whether +other+ is the same class as +self+, and all members are
 *  equal.
 *
 *  Examples:
 *
 *    Measure = Data.define(:amount, :unit)
 *
 *    Measure[1, 'km'] == Measure[1, 'km'] #=> true
 *    Measure[1, 'km'] == Measure[2, 'km'] #=> false
 *    Measure[1, 'km'] == Measure[1, 'm']  #=> false
 *
 *    Measurement = Data.define(:amount, :unit)
 *    # Even though Measurement and Measure have the same "shape"
 *    # their instances are never equal
 *    Measure[1, 'km'] == Measurement[1, 'km'] #=> false
 */

#define rb_data_equal rb_struct_equal

/*
 *  call-seq:
 *    self.eql?(other) -> true or false
 *
 *  Equality check that is used when two items of data are keys of a Hash.
 *
 *  The subtle difference with #== is that members are also compared with their
 *  #eql? method, which might be important in some cases:
 *
 *    Measure = Data.define(:amount, :unit)
 *
 *    Measure[1, 'km'] == Measure[1.0, 'km'] #=> true, they are equal as values
 *    # ...but...
 *    Measure[1, 'km'].eql? Measure[1.0, 'km'] #=> false, they represent different hash keys
 *
 *  See also Object#eql? for further explanations of the method usage.
 */

#define rb_data_eql rb_struct_eql

/*
 *  call-seq:
 *    hash -> integer
 *
 *  Redefines Object#hash (used to distinguish objects as Hash keys) so that
 *  data objects of the same class with same content would have the same +hash+
 *  value, and represented the same Hash key.
 *
 *    Measure = Data.define(:amount, :unit)
 *
 *    Measure[1, 'km'].hash == Measure[1, 'km'].hash #=> true
 *    Measure[1, 'km'].hash == Measure[10, 'km'].hash #=> false
 *    Measure[1, 'km'].hash == Measure[1, 'm'].hash #=> false
 *    Measure[1, 'km'].hash == Measure[1.0, 'km'].hash #=> false
 *
 *    # Structurally similar data class, but shouldn't be considered
 *    # the same hash key
 *    Measurement = Data.define(:amount, :unit)
 *
 *    Measure[1, 'km'].hash == Measurement[1, 'km'].hash #=> false
 */

#define rb_data_hash rb_struct_hash

/*
 *  call-seq:
 *    to_h -> hash
 *    to_h {|name, value| ... } -> hash
 *
 *  Returns Hash representation of the data object.
 *
 *    Measure = Data.define(:amount, :unit)
 *    distance = Measure[10, 'km']
 *
 *    distance.to_h
 *    #=> {amount: 10, unit: "km"}
 *
 *  Like Enumerable#to_h, if the block is provided, it is expected to
 *  produce key-value pairs to construct a hash:
 *
 *
 *    distance.to_h { |name, val| [name.to_s, val.to_s] }
 *    #=> {"amount"=>"10", "unit"=>"km"}
 *
 *  Note that there is a useful symmetry between #to_h and #initialize:
 *
 *   distance2 = Measure.new(**distance.to_h)
 *   #=> #<data Measure amount=10, unit="km">
 *   distance2 == distance
 *   #=> true
 */

#define rb_data_to_h rb_struct_to_h

/*
 *  call-seq:
 *    members -> array_of_symbols
 *
 *  Returns the member names from +self+ as an array:
 *
 *     Measure = Data.define(:amount, :unit)
 *     distance = Measure[10, 'km']
 *
 *     distance.members #=> [:amount, :unit]
 *
 */

#define rb_data_members_m rb_struct_members_m

/*
 *  call-seq:
 *    deconstruct     -> array
 *
 *  Returns the values in +self+ as an array, to use in pattern matching:
 *
 *    Measure = Data.define(:amount, :unit)
 *
 *    distance = Measure[10, 'km']
 *    distance.deconstruct #=> [10, "km"]
 *
 *    # usage
 *    case distance
 *    in n, 'km' # calls #deconstruct underneath
 *      puts "It is #{n} kilometers away"
 *    else
 *      puts "Don't know how to handle it"
 *    end
 *    # prints "It is 10 kilometers away"
 *
 *  Or, with checking the class, too:
 *
 *    case distance
 *    in Measure(n, 'km')
 *      puts "It is #{n} kilometers away"
 *    # ...
 *    end
 */

#define rb_data_deconstruct rb_struct_to_a

/*
 *  call-seq:
 *    deconstruct_keys(array_of_names_or_nil) -> hash
 *
 *  Returns a hash of the name/value pairs, to use in pattern matching.
 *
 *    Measure = Data.define(:amount, :unit)
 *
 *    distance = Measure[10, 'km']
 *    distance.deconstruct_keys(nil) #=> {amount: 10, unit: "km"}
 *    distance.deconstruct_keys([:amount]) #=> {amount: 10}
 *
 *    # usage
 *    case distance
 *    in amount:, unit: 'km' # calls #deconstruct_keys underneath
 *      puts "It is #{amount} kilometers away"
 *    else
 *      puts "Don't know how to handle it"
 *    end
 *    # prints "It is 10 kilometers away"
 *
 *  Or, with checking the class, too:
 *
 *    case distance
 *    in Measure(amount:, unit: 'km')
 *      puts "It is #{amount} kilometers away"
 *    # ...
 *    end
 */

static VALUE
rb_data_deconstruct_keys(VALUE s, VALUE keys)
{
    return deconstruct_keys(s, keys, true, rb_block_given_p());
}

/*
 *  Document-class: Struct
 *
 *  Class \Struct provides a convenient way to create a simple class
 *  that can store and fetch values.
 *
 *  This example creates a subclass of +Struct+, <tt>Struct::Customer</tt>;
 *  the first argument, a string, is the name of the subclass;
 *  the other arguments, symbols, determine the _members_ of the new subclass.
 *
 *    Customer = Struct.new('Customer', :name, :address, :zip)
 *    Customer.name       # => "Struct::Customer"
 *    Customer.class      # => Class
 *    Customer.superclass # => Struct
 *
 *  Corresponding to each member are two methods, a writer and a reader,
 *  that store and fetch values:
 *
 *    methods = Customer.instance_methods false
 *    methods # => [:zip, :address=, :zip=, :address, :name, :name=]
 *
 *  An instance of the subclass may be created,
 *  and its members assigned values, via method <tt>::new</tt>:
 *
 *    joe = Customer.new("Joe Smith", "123 Maple, Anytown NC", 12345)
 *    joe # => #<struct Struct::Customer name="Joe Smith", address="123 Maple, Anytown NC", zip=12345>
 *
 *  The member values may be managed thus:
 *
 *    joe.name    # => "Joe Smith"
 *    joe.name = 'Joseph Smith'
 *    joe.name    # => "Joseph Smith"
 *
 *  And thus; note that member name may be expressed as either a string or a symbol:
 *
 *    joe[:name]  # => "Joseph Smith"
 *    joe[:name] = 'Joseph Smith, Jr.'
 *    joe['name'] # => "Joseph Smith, Jr."
 *
 *  See Struct::new.
 *
 *  == What's Here
 *
 *  First, what's elsewhere. Class \Struct:
 *
 *  - Inherits from {class Object}[rdoc-ref:Object@Whats+Here].
 *  - Includes {module Enumerable}[rdoc-ref:Enumerable@Whats+Here],
 *    which provides dozens of additional methods.
 *
 *  See also Data, which is a somewhat similar, but stricter concept for defining immutable
 *  value objects.
 *
 *  Here, class \Struct provides methods that are useful for:
 *
 *  - {Creating a Struct Subclass}[rdoc-ref:Struct@Methods+for+Creating+a+Struct+Subclass]
 *  - {Querying}[rdoc-ref:Struct@Methods+for+Querying]
 *  - {Comparing}[rdoc-ref:Struct@Methods+for+Comparing]
 *  - {Fetching}[rdoc-ref:Struct@Methods+for+Fetching]
 *  - {Assigning}[rdoc-ref:Struct@Methods+for+Assigning]
 *  - {Iterating}[rdoc-ref:Struct@Methods+for+Iterating]
 *  - {Converting}[rdoc-ref:Struct@Methods+for+Converting]
 *
 *  === Methods for Creating a Struct Subclass
 *
 *  - ::new: Returns a new subclass of \Struct.
 *
 *  === Methods for Querying
 *
 *  - #hash: Returns the integer hash code.
 *  - #size (aliased as #length): Returns the number of members.
 *
 *  === Methods for Comparing
 *
 *  - #==: Returns whether a given object is equal to +self+, using <tt>==</tt>
 *    to compare member values.
 *  - #eql?: Returns whether a given object is equal to +self+,
 *    using <tt>eql?</tt> to compare member values.
 *
 *  === Methods for Fetching
 *
 *  - #[]: Returns the value associated with a given member name.
 *  - #to_a (aliased as #values, #deconstruct): Returns the member values in +self+ as an array.
 *  - #deconstruct_keys: Returns a hash of the name/value pairs
 *    for given member names.
 *  - #dig: Returns the object in nested objects that is specified
 *    by a given member name and additional arguments.
 *  - #members: Returns an array of the member names.
 *  - #select (aliased as #filter): Returns an array of member values from +self+,
 *    as selected by the given block.
 *  - #values_at: Returns an array containing values for given member names.
 *
 *  === Methods for Assigning
 *
 *  - #[]=: Assigns a given value to a given member name.
 *
 *  === Methods for Iterating
 *
 *  - #each: Calls a given block with each member name.
 *  - #each_pair: Calls a given block with each member name/value pair.
 *
 *  === Methods for Converting
 *
 *  - #inspect (aliased as #to_s): Returns a string representation of +self+.
 *  - #to_h: Returns a hash of the member name/value pairs in +self+.
 *
 */
void
InitVM_Struct(void)
{
    rb_cStruct = rb_define_class("Struct", rb_cObject);
    rb_include_module(rb_cStruct, rb_mEnumerable);

    rb_undef_alloc_func(rb_cStruct);
    rb_define_singleton_method(rb_cStruct, "new", rb_struct_s_def, -1);
#if 0 /* for RDoc */
    rb_define_singleton_method(rb_cStruct, "keyword_init?", rb_struct_s_keyword_init_p, 0);
    rb_define_singleton_method(rb_cStruct, "members", rb_struct_s_members_m, 0);
#endif

    rb_define_method(rb_cStruct, "initialize", rb_struct_initialize_m, -1);
    rb_define_method(rb_cStruct, "initialize_copy", rb_struct_init_copy, 1);

    rb_define_method(rb_cStruct, "==", rb_struct_equal, 1);
    rb_define_method(rb_cStruct, "eql?", rb_struct_eql, 1);
    rb_define_method(rb_cStruct, "hash", rb_struct_hash, 0);

    rb_define_method(rb_cStruct, "inspect", rb_struct_inspect, 0);
    rb_define_alias(rb_cStruct,  "to_s", "inspect");
    rb_define_method(rb_cStruct, "to_a", rb_struct_to_a, 0);
    rb_define_method(rb_cStruct, "to_h", rb_struct_to_h, 0);
    rb_define_method(rb_cStruct, "values", rb_struct_to_a, 0);
    rb_define_method(rb_cStruct, "size", rb_struct_size, 0);
    rb_define_method(rb_cStruct, "length", rb_struct_size, 0);

    rb_define_method(rb_cStruct, "each", rb_struct_each, 0);
    rb_define_method(rb_cStruct, "each_pair", rb_struct_each_pair, 0);
    rb_define_method(rb_cStruct, "[]", rb_struct_aref, 1);
    rb_define_method(rb_cStruct, "[]=", rb_struct_aset, 2);
    rb_define_method(rb_cStruct, "select", rb_struct_select, -1);
    rb_define_method(rb_cStruct, "filter", rb_struct_select, -1);
    rb_define_method(rb_cStruct, "values_at", rb_struct_values_at, -1);

    rb_define_method(rb_cStruct, "members", rb_struct_members_m, 0);
    rb_define_method(rb_cStruct, "dig", rb_struct_dig, -1);

    rb_define_method(rb_cStruct, "deconstruct", rb_struct_to_a, 0);
    rb_define_method(rb_cStruct, "deconstruct_keys", rb_struct_deconstruct_keys, 1);

    rb_cData = rb_define_class("Data", rb_cObject);

    rb_undef_method(CLASS_OF(rb_cData), "new");
    rb_undef_alloc_func(rb_cData);
    rb_define_singleton_method(rb_cData, "define", rb_data_s_def, -1);

#if 0 /* for RDoc */
    rb_define_singleton_method(rb_cData, "members", rb_data_s_members_m, 0);
#endif

    rb_define_method(rb_cData, "initialize", rb_data_initialize_m, -1);
    rb_define_method(rb_cData, "initialize_copy", rb_data_init_copy, 1);

    rb_define_method(rb_cData, "==", rb_data_equal, 1);
    rb_define_method(rb_cData, "eql?", rb_data_eql, 1);
    rb_define_method(rb_cData, "hash", rb_data_hash, 0);

    rb_define_method(rb_cData, "inspect", rb_data_inspect, 0);
    rb_define_alias(rb_cData,  "to_s", "inspect");
    rb_define_method(rb_cData, "to_h", rb_data_to_h, 0);

    rb_define_method(rb_cData, "members", rb_data_members_m, 0);

    rb_define_method(rb_cData, "deconstruct", rb_data_deconstruct, 0);
    rb_define_method(rb_cData, "deconstruct_keys", rb_data_deconstruct_keys, 1);

    rb_define_method(rb_cData, "with", rb_data_with, -1);
}

#undef rb_intern
void
Init_Struct(void)
{
    id_members = rb_intern("__members__");
    id_back_members = rb_intern("__members_back__");
    id_keyword_init = rb_intern("__keyword_init__");

    InitVM(Struct);
}
