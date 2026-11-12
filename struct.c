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
#include "vm_core.h"
#include "vm_callinfo.h"
#include "iseq.h"
#include "builtin.h"

rb_cref_t *rb_vm_cref_new_toplevel(void);

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
/* A Struct class keeps its ISEQ method entries in one hidden Array ivar,
 * out of the method table, so the usual methods stay the only visible ones.
 * These are the indexes into it. */
static ID id_struct_cmes;
enum { id_struct_pos_init, id_struct_kw_init, id_struct_pos_new, id_struct_kw_new, id_struct_new_c, STRUCT_CMES_LEN };

static VALUE struct_alloc(VALUE);
static void struct_define_kw_init(VALUE klass, VALUE members);

static inline VALUE
struct_ivar_get(VALUE c, ID id)
{
    VALUE orig = c;
    VALUE ivar = rb_attr_get(c, id);

    if (!NIL_P(ivar))
        return ivar;

    for (;;) {
        c = rb_class_superclass(c);
        if (c == rb_cStruct || c == rb_cData || !RTEST(c))
            return Qnil;
        RUBY_ASSERT(RB_TYPE_P(c, T_CLASS));
        ivar = rb_attr_get(c, id);
        if (!NIL_P(ivar)) {
            if (!OBJ_FROZEN(orig) && rb_class_owned_p(orig)) rb_ivar_set(orig, id, ivar);
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
struct_member_pos(VALUE s, VALUE name)
{
    VALUE back = struct_ivar_get(rb_obj_class(s), id_back_members);
    rb_len_t j, mask;

    if (UNLIKELY(NIL_P(back))) {
        rb_raise(rb_eTypeError, "uninitialized struct");
    }
    if (UNLIKELY(!RB_TYPE_P(back, T_ARRAY))) {
        rb_raise(rb_eTypeError, "corrupted struct");
    }

    mask = RARRAY_LEN(back);

    if (mask <= AREF_HASH_THRESHOLD) {
        if (UNLIKELY(RSTRUCT_LEN_RAW(s) != mask)) {
            rb_raise(rb_eTypeError,
                     "struct size differs (%"PRIdLEN" required %"PRIdLEN" given)",
                     mask, RSTRUCT_LEN_RAW(s));
        }
        for (j = 0; j < mask; j++) {
            if (RARRAY_AREF(back, j) == name)
                return (int)j;
        }
        return -1;
    }

    if (UNLIKELY(RSTRUCT_LEN_RAW(s) != FIX2INT(RARRAY_AREF(back, mask-1)))) {
        rb_raise(rb_eTypeError, "struct size differs (%d required %"PRIdLEN" given)",
                 FIX2INT(RARRAY_AREF(back, mask-1)), RSTRUCT_LEN_RAW(s));
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

static VALUE rb_data_initialize_m(int argc, const VALUE *argv, VALUE self);

// Given every member, Data#initialize can only store them and freeze the
// instance: it raises nothing and calls no Ruby code. So when initialize is
// that method, the members can be stored without calling it.
static bool
data_initialize_default_p(VALUE klass)
{
    const rb_callable_method_entry_t *cme = rb_callable_method_entry(klass, idInitialize);
    return cme && cme->def->type == VM_METHOD_TYPE_CFUNC &&
        cme->def->body.cfunc.func == (rb_cfunc_t)rb_data_initialize_m;
}

static VALUE
rb_data_s_new(int argc, const VALUE *argv, VALUE klass)
{
    if (rb_keyword_given_p()) {
        if (argc > 1 || !RB_TYPE_P(argv[0], T_HASH)) {
            rb_error_arity(argc, 0, 0);
        }
        return rb_class_new_instance_pass_kw(argc, argv, klass);
    }
    else {
        VALUE members = struct_ivar_get(klass, id_members);
        int num_members = RARRAY_LENINT(members);

        rb_check_arity(argc, 0, num_members);
        if (argc == num_members && data_initialize_default_p(klass)) {
            VALUE self = rb_obj_alloc(klass);
            for (rb_len_t i=0; i<argc; i++) {
                RSTRUCT_SET_RAW(self, i, argv[i]);
            }
            OBJ_FREEZE(self);
            return self;
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

static void struct_define_init_iseqs(VALUE klass);

static void
struct_reserve_init_ivars(VALUE klass)
{
    /* Class ivars are looked up from the newest one, and struct_alloc() looks
     * up __members__ on every allocation, so add this before it. */
    VALUE cmes = rb_ary_hidden_new(STRUCT_CMES_LEN);
    for (int i = 0; i < STRUCT_CMES_LEN; i++) rb_ary_push(cmes, Qnil);
    rb_ivar_set(klass, id_struct_cmes, cmes);
}

static VALUE
setup_struct(VALUE nstr, VALUE members)
{
    rb_len_t i, len;

    struct_reserve_init_ivars(nstr);
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

    if (rb_class_inherited_p(klass, rb_cStruct) == Qtrue) struct_reserve_init_ivars(klass);
    struct_set_members(klass, members);

    if (alloc) {
        rb_define_alloc_func(klass, alloc);
    }
    else {
        rb_define_alloc_func(klass, struct_alloc);
    }
    if (rb_class_inherited_p(klass, rb_cStruct) == Qtrue) struct_define_init_iseqs(klass);

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
    setup_struct(st, ary);
    struct_define_init_iseqs(st);
    return st;
}

VALUE
rb_struct_define_under(VALUE outer, const char *name, ...)
{
    va_list ar;
    VALUE ary;

    va_start(ar, name);
    ary = struct_make_members_list(ar);
    va_end(ar);

    VALUE st = setup_struct(rb_define_class_id_under(outer, rb_intern(name), rb_cStruct), ary);
    struct_define_init_iseqs(st);
    return st;
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
    struct_define_init_iseqs(st);
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
    bool *found; // Data#initialize: which members were given
    rb_len_t missing_count;
};

static int rb_struct_pos(VALUE s, VALUE *name, bool name_only);
static VALUE deconstruct_keys(VALUE s, VALUE keys, bool name_only);
static int rb_struct_pos(VALUE s, VALUE *name, bool name_only);

static int
struct_hash_aset(VALUE key, VALUE val, struct struct_hash_set_arg *args, bool name_only)
{
    int i = rb_struct_pos(args->self, &key, name_only);
    if (i < 0) {
        if (!args->unknown_keywords) {
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

/*
 * Struct#initialize is OPTIMIZED_METHOD_TYPE_STRUCT_INIT and has no body of
 * its own. Each call goes to one of these ISEQ methods, chosen from the call
 * shape by rb_struct_init_target():
 *
 *   positional  initialize(m0 = nil, ..., m(n-1) = nil)   defined per class
 *   keyword     initialize(m0: nil, ..., m(n-1): nil)     defined per class
 *   generic     initialize(*args, **kw)                   struct.rb
 *
 * A call mixing positional and keyword arguments goes to the positional
 * ISEQ: it has no keyword parameters, so the VM passes the keywords as a
 * trailing Hash, which is what Struct does with them. The generic ISEQ takes
 * what the call site cannot decide (splats, calls without a call site such
 * as send or rb_funcall) and the error cases.
 */
static const rb_callable_method_entry_t *struct_generic_init_cme;

const rb_callable_method_entry_t *
rb_struct_generic_init_cme(void)
{
    return struct_generic_init_cme;
}

static const rb_callable_method_entry_t *
struct_init_cme(VALUE klass, int idx)
{
    VALUE cmes = struct_ivar_get(klass, id_struct_cmes);
    VALUE cme = NIL_P(cmes) ? Qnil : RARRAY_AREF(cmes, idx);
    return NIL_P(cme) ? NULL : (const rb_callable_method_entry_t *)cme;
}

static void
struct_set_cme(VALUE klass, int idx, VALUE cme)
{
    rb_ary_store(rb_attr_get(klass, id_struct_cmes), idx, cme);
}

static bool
struct_keywords_are_members(VALUE klass, const struct rb_callinfo_kwarg *kwarg)
{
    VALUE members = struct_ivar_get(klass, id_members);
    for (int i = 0; i < kwarg->keyword_len; i++) {
        if (!rb_ary_includes(members, kwarg->keywords[i])) return false;
    }
    return true;
}

/*
 * The target of Struct#initialize for a call with ci on an instance of klass.
 * Everything but the keyword names depends only on argc, flags and keyword
 * count, which is what call caches are keyed by.
 */
const rb_callable_method_entry_t *
rb_struct_init_target(VALUE klass, const struct rb_callinfo *ci)
{
    const rb_callable_method_entry_t *cme = NULL;
    const struct rb_callinfo_kwarg *kwarg = vm_ci_kwarg(ci);
    int argc = vm_ci_argc(ci);
    int kw_len = kwarg ? kwarg->keyword_len : 0;

    if (vm_ci_flag(ci) & (VM_CALL_ARGS_SPLAT | VM_CALL_KW_SPLAT | VM_CALL_ARGS_BLOCKARG | VM_CALL_FORWARDING)) {
        return struct_generic_init_cme;
    }

    VALUE keyword_init = rb_struct_s_keyword_init(klass);
    if (keyword_init == Qfalse) {
        int npos = argc - kw_len + (kw_len > 0);
        if (npos <= num_members(klass)) cme = struct_init_cme(klass, id_struct_pos_init);
    }
    else if (kw_len == argc) {
        if (kw_len == 0 || struct_keywords_are_members(klass, kwarg)) {
            cme = struct_init_cme(klass, id_struct_kw_init);
        }
    }
    else if (NIL_P(keyword_init)) {
        int npos = argc - kw_len + (kw_len > 0);
        if (npos <= num_members(klass)) cme = struct_init_cme(klass, id_struct_pos_init);
    }
    return cme ? cme : struct_generic_init_cme;
}

/*
 * The arrays and hashes given to rb_iseq_load() hold symbols of internal IDs,
 * which cannot be inspected. Hide them so ObjectSpace never yields them.
 */
static VALUE
iseq_hidden_ary(long capa)
{
    return rb_ary_hidden_new(capa);
}

static VALUE
iseq_hidden_hash(void)
{
    VALUE hash = rb_hash_new();
    RBASIC_CLEAR_CLASS(hash);
    return hash;
}

static VALUE
iseq_hidden_dup(VALUE ary)
{
    VALUE dup = rb_ary_hidden_new(RARRAY_LEN(ary));
    rb_ary_concat(dup, ary);
    return dup;
}

static VALUE
iseq_hidden_from_args(long n, ...)
{
    VALUE ary = rb_ary_hidden_new(n);
    va_list ap;
    va_start(ap, n);
    for (long i = 0; i < n; i++) rb_ary_push(ary, va_arg(ap, VALUE));
    va_end(ap);
    return ary;
}

/*
 * Whether a call with ci on an instance of klass goes to the positional ISEQ.
 * rb_struct_init_target() looks at keyword names only to pick the keyword
 * ISEQ, so this depends only on klass, argc and flags, all of which the call
 * cache is keyed by.
 */
bool
rb_struct_init_pos_target_p(VALUE klass, const struct rb_callinfo *ci)
{
    const rb_callable_method_entry_t *pos = struct_init_cme(klass, id_struct_pos_init);
    return pos && rb_struct_init_target(klass, ci) == pos;
}

/* Whether ci passes only a keyword splat, and klass has a keyword ISEQ for it. */
bool
rb_struct_init_kwsplat_p(VALUE klass, const struct rb_callinfo *ci)
{
    return (vm_ci_flag(ci) & VM_CALL_KW_SPLAT) && vm_ci_argc(ci) == 1 &&
        !(vm_ci_flag(ci) & (VM_CALL_ARGS_SPLAT | VM_CALL_KWARG | VM_CALL_ARGS_BLOCKARG | VM_CALL_FORWARDING)) &&
        struct_init_cme(klass, id_struct_kw_init);
}

static int
struct_member_key_i(VALUE key, VALUE val, VALUE arg)
{
    VALUE *args = (VALUE *)arg; /* recv, bool *ok */
    if (!SYMBOL_P(key) || struct_member_pos(args[0], key) < 0) {
        *(bool *)args[1] = false;
        return ST_STOP;
    }
    return ST_CONTINUE;
}

/*
 * The target for a call of rb_struct_init_kwsplat_p() with hash. The keyword
 * ISEQ takes it when every key is a member name; String or Integer keys and
 * unknown keys go to the generic ISEQ, which has Struct's own rules for them.
 */
const rb_callable_method_entry_t *
rb_struct_init_kwsplat_target(VALUE recv, VALUE hash)
{
    if (RB_TYPE_P(hash, T_HASH)) {
        long n = RHASH_SIZE(hash);
        if (n == 0) return struct_init_cme(rb_obj_class(recv), id_struct_kw_init);
        if (n <= RSTRUCT_LEN_RAW(recv)) {
            bool ok = true;
            VALUE args[2] = { recv, (VALUE)&ok };
            rb_hash_foreach(hash, struct_member_key_i, (VALUE)args);
            if (ok) return struct_init_cme(rb_obj_class(recv), id_struct_kw_init);
        }
    }
    return struct_generic_init_cme;
}

/* Whether klass has a positional ISEQ that takes splat calls. */
bool
rb_struct_init_splat_class_p(VALUE klass)
{
    return rb_struct_s_keyword_init(klass) != Qtrue && struct_init_cme(klass, id_struct_pos_init);
}

/* Whether ci passes a splat and nothing else that needs the generic ISEQ. */
bool
rb_struct_init_splat_shape_p(const struct rb_callinfo *ci)
{
    return (vm_ci_flag(ci) & VM_CALL_ARGS_SPLAT) &&
        !(vm_ci_flag(ci) & (VM_CALL_KW_SPLAT | VM_CALL_KWARG | VM_CALL_ARGS_BLOCKARG | VM_CALL_FORWARDING));
}

/*
 * The target for a call of rb_struct_init_splat_shape_p(), given the splatted
 * Array. The positional ISEQ takes it when the values fit the members and the
 * last one is not a ruby2_keywords Hash, which Struct takes as keywords.
 */
const rb_callable_method_entry_t *
rb_struct_init_splat_target(VALUE klass, const struct rb_callinfo *ci, VALUE splat)
{
    const rb_callable_method_entry_t *pos = struct_init_cme(klass, id_struct_pos_init);
    if (!pos || !RB_TYPE_P(splat, T_ARRAY) || rb_struct_s_keyword_init(klass) == Qtrue) {
        return struct_generic_init_cme;
    }
    long len = RARRAY_LEN(splat);
    if ((long)vm_ci_argc(ci) - 1 + len > num_members(klass)) return struct_generic_init_cme;
    if (len > 0) {
        VALUE last = RARRAY_AREF(splat, len - 1);
        if (RB_TYPE_P(last, T_HASH) && FL_TEST_RAW(last, RHASH_PASS_AS_KEYWORDS)) return struct_generic_init_cme;
    }
    return pos;
}

const rb_callable_method_entry_t *
rb_struct_pos_init_cme(VALUE klass)
{
    return struct_init_cme(klass, id_struct_pos_init);
}

/*
 * Same as rb_struct_init_target() for a call without a call site (send,
 * Method#call, rb_funcall), where only argc and whether the last argument
 * is keywords are known.
 */
const rb_callable_method_entry_t *
rb_struct_init_target_argc(VALUE recv, int argc, const VALUE *argv, int kw_splat)
{
    VALUE klass = rb_obj_class(recv);
    const rb_callable_method_entry_t *cme = NULL;
    if (kw_splat && argc == 1 && struct_init_cme(klass, id_struct_kw_init)) {
        return rb_struct_init_kwsplat_target(recv, argv[0]);
    }
    if (!kw_splat && rb_struct_s_keyword_init(klass) != Qtrue && argc <= num_members(klass)) {
        cme = struct_init_cme(klass, id_struct_pos_init);
    }
    return cme ? cme : struct_generic_init_cme;
}

struct iseq_ary_builder {
    VALUE body;
    long insn_count;
    int local_size;
};

#define ISEQ_SYM(s) ID2SYM(rb_intern(s))

static void
iseq_insn(struct iseq_ary_builder *b, const char *name, int argc, ...)
{
    VALUE insn = iseq_hidden_ary(argc + 1);
    rb_ary_push(insn, ISEQ_SYM(name));
    va_list ap;
    va_start(ap, argc);
    for (int i = 0; i < argc; i++) {
        rb_ary_push(insn, va_arg(ap, VALUE));
    }
    va_end(ap);
    rb_ary_push(b->body, insn);
    b->insn_count++;
}

static VALUE
iseq_label(long i)
{
    char buf[32];
    snprintf(buf, sizeof(buf), "label_%ld", i);
    return ISEQ_SYM(buf);
}

/* Local operand for getlocal/setlocal: index counted from the EP. */
static VALUE
iseq_lidx(struct iseq_ary_builder *b, long i)
{
    return INT2FIX(b->local_size - i + VM_ENV_DATA_SIZE - 1);
}

/* Store local j into member j, for every member. */
static void
iseq_store_members(struct iseq_ary_builder *b, long n)
{
    rb_ary_push(b->body, ISEQ_SYM("RUBY_EVENT_CALL"));
    for (long j = 0; j < n; j++) {
        iseq_insn(b, "getlocal_WC_0", 1, iseq_lidx(b, j));
        iseq_insn(b, "setstructmember", 1, LONG2FIX(j));
    }
    iseq_insn(b, "putnil", 0);
    rb_ary_push(b->body, ISEQ_SYM("RUBY_EVENT_RETURN"));
    iseq_insn(b, "leave", 0);
}

static void
struct_add_iseq(VALUE klass, int idx, ID name, VALUE owner, rb_method_visibility_t visi, int stack_max,
                struct iseq_ary_builder *b, int arg_size, VALUE locals, VALUE params)
{
    VALUE node_ids = iseq_hidden_ary(b->insn_count);
    for (long i = 0; i < b->insn_count; i++) rb_ary_push(node_ids, INT2FIX(0));

    VALUE misc = iseq_hidden_hash();
    rb_hash_aset(misc, ISEQ_SYM("arg_size"), INT2FIX(arg_size));
    rb_hash_aset(misc, ISEQ_SYM("local_size"), INT2FIX(b->local_size));
    rb_hash_aset(misc, ISEQ_SYM("stack_max"), INT2FIX(stack_max));
    rb_hash_aset(misc, ISEQ_SYM("node_id"), INT2FIX(0));
    rb_hash_aset(misc, ISEQ_SYM("node_ids"), node_ids);
    rb_hash_aset(misc, ISEQ_SYM("parser"), ISEQ_SYM("prism"));

    VALUE data = iseq_hidden_from_args(14,
        rb_str_new_cstr("YARVInstructionSequence/SimpleDataFormat"),
        INT2FIX(ISEQ_MAJOR_VERSION), INT2FIX(ISEQ_MINOR_VERSION), INT2FIX(1),
        misc, rb_id2str(name), rb_str_new_cstr("<internal:struct>"), Qnil,
        INT2FIX(1), ISEQ_SYM("method"), locals, params, iseq_hidden_ary(0), b->body);

    const rb_iseq_t *iseq = rb_iseqw_to_iseq(rb_iseq_load(data, Qnil, Qnil));
    /* Named and owned as the method it stands for, as TracePoint and backtraces show it. */
    rb_method_definition_t *def = rb_method_definition_create(VM_METHOD_TYPE_ISEQ, name);
    rb_method_entry_t *me = rb_method_entry_create(name, owner, visi, NULL);
    rb_method_iseq_t body = { .iseqptr = iseq, .cref = rb_vm_cref_new_toplevel() };
    rb_method_definition_set(me, def, &body);
    struct_set_cme(klass, idx, (VALUE)me);
}

/* initialize(m0 = nil, ..., m(n-1) = nil) */
static void
struct_define_pos_init(VALUE klass, VALUE members)
{
    long n = RARRAY_LEN(members);
    struct iseq_ary_builder b = { iseq_hidden_ary(0), 0, (int)n };
    VALUE locals = iseq_hidden_dup(members);
    VALUE opt = iseq_hidden_ary(n + 1);
    for (long j = 0; j < n; j++) {
        rb_ary_push(opt, iseq_label(j));
        rb_ary_push(b.body, iseq_label(j));
        iseq_insn(&b, "putnil", 0);
        iseq_insn(&b, "setlocal_WC_0", 1, iseq_lidx(&b, j));
    }
    rb_ary_push(opt, iseq_label(n));
    rb_ary_push(b.body, iseq_label(n));
    iseq_store_members(&b, n);

    VALUE params = iseq_hidden_hash();
    rb_hash_aset(params, ISEQ_SYM("opt"), opt);
    struct_add_iseq(klass, id_struct_pos_init, idInitialize, rb_cStruct, METHOD_VISI_PRIVATE, 2, &b, (int)n, locals, params);
}

/* initialize(m0: nil, ..., m(n-1): nil) */
static void
struct_define_kw_init(VALUE klass, VALUE members)
{
    long n = RARRAY_LEN(members);
    /* locals: m0..m(n-1), kwbits */
    struct iseq_ary_builder b = { iseq_hidden_ary(0), 0, (int)(n + 1) };
    VALUE locals = iseq_hidden_dup(members);
    rb_ary_push(locals, INT2FIX(0));
    VALUE keywords = iseq_hidden_ary(n);
    for (long j = 0; j < n; j++) {
        rb_ary_push(keywords, rb_ary_new_from_args(2, RARRAY_AREF(members, j), Qnil));
    }
    iseq_store_members(&b, n);

    VALUE params = iseq_hidden_hash();
    rb_hash_aset(params, ISEQ_SYM("keyword"), keywords);
    rb_hash_aset(params, ISEQ_SYM("kwbits"), LONG2FIX(n));
    struct_add_iseq(klass, id_struct_kw_init, idInitialize, rb_cStruct, METHOD_VISI_PRIVATE, 2, &b, b.local_size, locals, params);
}

/* Build an instance of self from locals 0..n-1 and return it. */
static void
iseq_new_struct(struct iseq_ary_builder *b, long n)
{
    rb_ary_push(b->body, ISEQ_SYM("RUBY_EVENT_CALL"));
    for (long j = 0; j < n; j++) {
        iseq_insn(b, "getlocal_WC_0", 1, iseq_lidx(b, j));
    }
    iseq_insn(b, "newstruct", 1, LONG2FIX(n));
    rb_ary_push(b->body, ISEQ_SYM("RUBY_EVENT_RETURN"));
    iseq_insn(b, "leave", 0);
}

/*
 * Struct.[] of klass, used only while klass has Struct#initialize, which
 * would store the given members and nil for the rest. So these build the
 * instance directly:
 *
 *   positional  [](m0 = nil, ..., m(n-1) = nil)
 *   keyword     [](m0: nil, ..., m(n-1): nil)
 */
static void
struct_define_new(VALUE klass, VALUE members, bool pos, bool kw)
{
    long n = RARRAY_LEN(members);
    VALUE owner = rb_singleton_class(klass);
    if (pos) {
        struct iseq_ary_builder b = { iseq_hidden_ary(0), 0, (int)n };
        VALUE locals = iseq_hidden_dup(members);
        VALUE opt = iseq_hidden_ary(n + 1);
        for (long j = 0; j < n; j++) {
            rb_ary_push(opt, iseq_label(j));
            rb_ary_push(b.body, iseq_label(j));
            iseq_insn(&b, "putnil", 0);
            iseq_insn(&b, "setlocal_WC_0", 1, iseq_lidx(&b, j));
        }
        rb_ary_push(opt, iseq_label(n));
        rb_ary_push(b.body, iseq_label(n));
        iseq_new_struct(&b, n);
        VALUE params = iseq_hidden_hash();
        rb_hash_aset(params, ISEQ_SYM("opt"), opt);
        struct_add_iseq(klass, id_struct_pos_new, idAREF, owner, METHOD_VISI_PUBLIC, (int)n + 2, &b, (int)n, locals, params);
    }
    if (kw) {
        struct iseq_ary_builder b = { iseq_hidden_ary(0), 0, (int)(n + 1) };
        VALUE locals = iseq_hidden_dup(members);
        rb_ary_push(locals, INT2FIX(0));
        VALUE keywords = iseq_hidden_ary(n);
        for (long j = 0; j < n; j++) {
            rb_ary_push(keywords, rb_ary_new_from_args(2, RARRAY_AREF(members, j), Qnil));
        }
        iseq_new_struct(&b, n);
        VALUE params = iseq_hidden_hash();
        rb_hash_aset(params, ISEQ_SYM("keyword"), keywords);
        rb_hash_aset(params, ISEQ_SYM("kwbits"), LONG2FIX(n));
        struct_add_iseq(klass, id_struct_kw_new, idAREF, owner, METHOD_VISI_PUBLIC, (int)n + 2, &b, b.local_size, locals, params);
    }
}

#undef ISEQ_SYM

static void
struct_define_init_iseqs(VALUE klass)
{
    /* Until struct.rb is loaded, every call goes to the generic ISEQ, which
     * does not exist yet either; no Struct is initialized that early. */
    if (!struct_generic_init_cme) return;

    VALUE members = struct_ivar_get(klass, id_members);
    VALUE keyword_init = rb_struct_s_keyword_init(klass);
    long n = RARRAY_LEN(members);
    if (n == 0) return;

    bool pos = keyword_init != Qtrue;
    bool kw = keyword_init != Qfalse && n <= VM_KW_SPECIFIED_BITS_MAX;
    if (pos) struct_define_pos_init(klass, members);
    if (kw) struct_define_kw_init(klass, members);

    /* Struct.[] becomes a dispatcher too, when klass has the usual one. */
    VALUE sclass = rb_singleton_class(klass);
    const rb_method_entry_t *aref = rb_method_entry_at(sclass, idAREF);
    if (aref && aref->def->type == VM_METHOD_TYPE_CFUNC &&
        (void *)aref->def->body.cfunc.func == (void *)rb_class_new_instance_pass_kw) {
        struct_set_cme(klass, id_struct_new_c, (VALUE)rb_method_entry_clone(aref));
        struct_define_new(klass, members, pos, kw);
        rb_add_method_optimized(sclass, idAREF, OPTIMIZED_METHOD_TYPE_STRUCT_NEW, 0, METHOD_VISI_PUBLIC);
    }
}

/* The original Struct.[] of klass: allocate and call #initialize, from C. */
const rb_callable_method_entry_t *
rb_struct_new_c_cme(VALUE klass)
{
    return struct_init_cme(klass, id_struct_new_c);
}

/* The #initialize that Struct.[] of klass would call. */
const rb_callable_method_entry_t *
rb_struct_new_init_cme(VALUE klass)
{
    return rb_callable_method_entry(klass, idInitialize);
}

/*
 * Whether Struct.[] of klass may use its ISEQs: #initialize is Struct's own,
 * and no call event is traced, as the ISEQs do not call #initialize.
 */
bool
rb_struct_new_iseq_p(VALUE klass)
{
    if (UNLIKELY(ruby_vm_event_enabled_global_flags & (RUBY_EVENT_CALL | RUBY_EVENT_C_CALL))) return false;
    const rb_callable_method_entry_t *init = rb_struct_new_init_cme(klass);
    return init && init->def->type == VM_METHOD_TYPE_OPTIMIZED &&
        init->def->body.optimized.type == OPTIMIZED_METHOD_TYPE_STRUCT_INIT;
}

const rb_callable_method_entry_t *
rb_struct_pos_new_cme(VALUE klass)
{
    return struct_init_cme(klass, id_struct_pos_new);
}

/*
 * The target of Struct.[] for a call with ci on klass. The ISEQs pass every
 * member to #initialize, so they are used only while that is Struct's own;
 * they go where Struct#initialize would send the same call.
 */
const rb_callable_method_entry_t *
rb_struct_new_target(VALUE klass, const struct rb_callinfo *ci)
{
    if (rb_struct_new_iseq_p(klass) && !(vm_ci_flag(ci) & VM_CALL_OPT_SEND)) {
        const rb_callable_method_entry_t *target = rb_struct_init_target(klass, ci);
        if (target == struct_init_cme(klass, id_struct_pos_init)) return struct_init_cme(klass, id_struct_pos_new);
        if (target == struct_init_cme(klass, id_struct_kw_init)) return struct_init_cme(klass, id_struct_kw_new);
    }
    return rb_struct_new_c_cme(klass);
}

static VALUE
struct_set_raw(rb_execution_context_t *ec, VALUE self, VALUE idx, VALUE val)
{
    long i = FIX2LONG(idx);
    if (i < 0 || RSTRUCT_LEN_RAW(self) <= i) rb_bug("struct_set_raw: index %ld out of range", i);
    RSTRUCT_SET_RAW(self, i, val);
    return val;
}

static VALUE
struct_symbol_p(rb_execution_context_t *ec, VALUE self, VALUE key)
{
    return RBOOL(SYMBOL_P(key));
}

static VALUE
struct_string_p(rb_execution_context_t *ec, VALUE self, VALUE key)
{
    return RBOOL(RB_TYPE_P(key, T_STRING));
}

static VALUE
struct_member_index(rb_execution_context_t *ec, VALUE self, VALUE sym)
{
    int i = struct_member_pos(self, sym);
    return i < 0 ? Qnil : INT2FIX(i);
}

static VALUE
struct_check_symbol(rb_execution_context_t *ec, VALUE self, VALUE str)
{
    return rb_check_symbol(&str);
}

static VALUE
struct_num2len(rb_execution_context_t *ec, VALUE self, VALUE key)
{
    return LEN2NUM(NUM2LEN(key));
}

static VALUE
struct_register_generic_init(rb_execution_context_t *ec, VALUE self)
{
    /* struct.rb has just defined Struct#initialize as the generic ISEQ. */
    const rb_method_entry_t *me = rb_method_entry_at(rb_cStruct, idInitialize);
    struct_generic_init_cme = (const rb_callable_method_entry_t *)rb_method_entry_clone(me);
    rb_vm_register_global_object((VALUE)struct_generic_init_cme);
    rb_add_method_optimized(rb_cStruct, idInitialize, OPTIMIZED_METHOD_TYPE_STRUCT_INIT, 0, METHOD_VISI_PRIVATE);
    return Qnil;
}

VALUE
rb_struct_initialize(VALUE self, VALUE values)
{
    if (rb_obj_is_kind_of(self, rb_cData)) {
        rb_struct_modify(self);
        /* Marshal.load of a Data passes every member, in order. */
        long n = RSTRUCT_LEN_RAW(self);
        if (n < RARRAY_LEN(values)) rb_raise(rb_eArgError, "struct size differs");
        for (long i = 0; i < n; i++) {
            RSTRUCT_SET_RAW(self, i, i < RARRAY_LEN(values) ? RARRAY_AREF(values, i) : Qnil);
        }
        OBJ_FREEZE(self);
    }
    else {
        rb_execution_context_t *ec = GET_EC();
        rb_vm_call_kw(ec, self, idInitialize, RARRAY_LENINT(values), RARRAY_CONST_PTR(values),
                      struct_generic_init_cme, RB_NO_KEYWORDS);
    }
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

static VALUE
inspect_struct(VALUE s, VALUE prefix, int recur)
{
    VALUE cname = rb_class_path(rb_obj_class(s));
    VALUE members;
    VALUE str = prefix;
    rb_len_t i, len;
    char first = RSTRING_PTR(cname)[0];

    if (recur || first != '#') {
        rb_str_cat2(str, " ");
        rb_str_append(str, cname);
    }
    if (recur) {
        return rb_str_cat2(str, ":...>");
    }

    members = rb_struct_members(s);
    len = RSTRUCT_LEN_RAW(s);

    for (i=0; i<len; i++) {
        VALUE slot;
        ID id;

        if (i > 0) {
            rb_str_cat2(str, ", ");
        }
        else {
            rb_str_cat2(str, " ");
        }
        slot = RARRAY_AREF(members, i);
        id = SYM2ID(slot);
        if (rb_is_local_id(id) || rb_is_const_id(id)) {
            rb_str_append(str, rb_sym2str(slot));
        }
        else {
            rb_str_append(str, rb_inspect(slot));
        }
        rb_str_cat2(str, "=");
        rb_str_append(str, rb_inspect(RSTRUCT_GET_RAW(s, i)));
    }
    rb_str_cat2(str, ">");

    return str;
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
    return rb_exec_recursive(inspect_struct, s, rb_str_new2("#<struct"));
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
rb_struct_to_h(VALUE s)
{
    VALUE h = rb_hash_new_capa(RSTRUCT_LEN_RAW(s));
    VALUE members = rb_struct_members(s);
    rb_len_t i;
    int block_given = rb_block_given_p();

    for (i=0; i<RSTRUCT_LEN_RAW(s); i++) {
        VALUE k = rb_ary_entry(members, i), v = RSTRUCT_GET_RAW(s, i);
        if (block_given)
            rb_hash_set_pair(h, rb_yield_values(2, k, v));
        else
            rb_hash_aset(h, k, v);
    }
    return h;
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
    return deconstruct_keys(s, keys, false);
}

static VALUE
deconstruct_keys(VALUE s, VALUE keys, bool name_only)
{
    VALUE h;
    rb_len_t i;

    if (NIL_P(keys)) {
        return rb_struct_to_h(s);
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
    for (i=0; i<RARRAY_LEN(keys); i++) {
        VALUE key = RARRAY_AREF(keys, i);
        int i = rb_struct_pos(s, &key, name_only);
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

static int
rb_struct_pos(VALUE s, VALUE *name, bool name_only)
{
    rb_len_t i;
    VALUE idx = *name;

    if (SYMBOL_P(idx)) {
        return struct_member_pos(s, idx);
    }
    else if (name_only || RB_TYPE_P(idx, T_STRING)) {
        idx = rb_check_symbol(name);
        if (NIL_P(idx)) return -1;
        return struct_member_pos(s, idx);
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
    if (rb_obj_class(s) != rb_obj_class(s2)) return Qfalse;
    if (RSTRUCT_LEN_RAW(s) != RSTRUCT_LEN_RAW(s2)) {
        rb_bug("inconsistent struct"); /* should never happen */
    }

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

static VALUE
rb_struct_hash(VALUE s)
{
    rb_len_t i, len;
    st_index_t h;
    VALUE n;

    h = rb_hash_start(rb_hash(rb_obj_class(s)));
    len = RSTRUCT_LEN_RAW(s);
    for (i = 0; i < len; i++) {
        n = rb_hash(RSTRUCT_GET_RAW(s, i));
        h = rb_hash_uint(h, NUM2LONG(n));
    }
    h = rb_hash_end(h);
    return ST2FIX(h);
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
    if (rb_obj_class(s) != rb_obj_class(s2)) return Qfalse;
    if (RSTRUCT_LEN_RAW(s) != RSTRUCT_LEN_RAW(s2)) {
        rb_bug("inconsistent struct"); /* should never happen */
    }

    return rb_exec_recursive_paired(recursive_eql, s, s2, s2);
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
        args->found[i] = true;
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
    rb_struct_modify(self);
    rb_len_t num_members = RSTRUCT_LEN_RAW(self);

    if (argc == 0) {
        if (num_members > 0) {
            rb_exc_raise(rb_keyword_error_new("missing", struct_ivar_get(rb_obj_class(self), id_members)));
        }
        OBJ_FREEZE(self);
        return Qnil;
    }
    if (argc > 1 || !RB_TYPE_P(argv[0], T_HASH)) {
        rb_error_arity(argc, 0, 0);
    }

    VALUE found_buffer = 0;
    bool *found = NULL;
    if (num_members > 0) {
        found = ALLOCV_N(bool, found_buffer, num_members);
        MEMZERO(found, bool, num_members);
    }
    struct struct_hash_set_arg arg = {
        .self = self,
        .found = found,
        .missing_count = num_members,
    };
    rb_mem_clear((VALUE *)RSTRUCT_CONST_PTR(self), num_members);
    rb_hash_foreach(argv[0], data_hash_set_i, (VALUE)&arg);

    // Freeze early before potentially raising, so that we don't leave an
    // unfrozen copy on the heap, which could get exposed via ObjectSpace.
    OBJ_FREEZE(self);
    if (UNLIKELY(arg.missing_count > 0)) {
        VALUE members = struct_ivar_get(rb_obj_class(self), id_members);
        RUBY_ASSERT(RARRAY_LEN(members) == num_members);
        VALUE missing = rb_ary_new_capa(arg.missing_count);
        for (rb_len_t i = 0; i < num_members; i++) {
            if (!found[i]) rb_ary_push(missing, RARRAY_AREF(members, i));
        }
        RUBY_ASSERT(RARRAY_LEN(missing) == arg.missing_count, "missing_count=%"PRIdLEN" but %"PRIdLEN, arg.missing_count, RARRAY_LEN(missing));
        rb_exc_raise(rb_keyword_error_new("missing", missing));
    }

    ALLOCV_END(found_buffer);
    if (UNLIKELY(arg.unknown_keywords)) {
        rb_exc_raise(rb_keyword_error_new("unknown", arg.unknown_keywords));
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

static VALUE
rb_data_with(int argc, const VALUE *argv, VALUE self)
{
    VALUE kwargs;
    rb_scan_args(argc, argv, "0:", &kwargs);
    if (NIL_P(kwargs)) {
        return self;
    }

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
    return rb_exec_recursive(inspect_struct, s, rb_str_new2("#<data"));
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
    return deconstruct_keys(s, keys, true);
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

    /* Struct#initialize is defined by struct.rb. */
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

#include "struct.rbinc"

#undef rb_intern
void
Init_Struct(void)
{
    id_members = rb_intern("__members__");
    id_back_members = rb_intern("__members_back__");
    id_keyword_init = rb_intern("__keyword_init__");
    id_struct_cmes = rb_make_internal_id();

    InitVM(Struct);
}
