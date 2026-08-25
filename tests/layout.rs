use core::mem::size_of;

use scylla::syntax::css::semantic::Definition;
use scylla::syntax::go::semantic::{Binding as GoBinding, Reference as GoReference};
use scylla::syntax::javascript::semantic::{
    Binding as JavaScriptBinding,
    Reference as JavaScriptReference,
};
use scylla::syntax::odin::semantic::Binding as OdinBinding;
use scylla::syntax::python::semantic::{Binding as PythonBinding, Reference as PythonReference};
use scylla::syntax::rust::kind::RustKind;
use scylla::syntax::rust::semantic::Binding as RustBinding;
use scylla::syntax::zig::semantic::Binding as ZigBinding;
use scylla::token::Token;
use scylla::tree::{Events, Node};

#[test]
fn the_hot_rows_hold_their_size() {
    assert_eq!(size_of::<Token>(), 12);
    assert_eq!(size_of::<Node<RustKind>>(), 24);
    assert_eq!(size_of::<Definition>(), 24);
    assert_eq!(size_of::<GoBinding>(), 36);
    assert_eq!(size_of::<GoReference>(), 28);
    assert_eq!(size_of::<JavaScriptBinding>(), 36);
    assert_eq!(size_of::<JavaScriptReference>(), 28);
    assert_eq!(size_of::<OdinBinding>(), 36);
    assert_eq!(size_of::<PythonBinding>(), 48);
    assert_eq!(size_of::<PythonReference>(), 40);
    assert_eq!(size_of::<RustBinding>(), 36);
    assert_eq!(size_of::<ZigBinding>(), 36);
}

#[test]
fn the_replay_stacks_live_on_the_reserved_table() {
    assert_eq!(size_of::<Events<RustKind>>(), 18_472);
}
