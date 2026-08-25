use scylla::syntax::Category;

macro_rules! projection {
    ($module:ident, $kind:ty, $count:path) => {
        mod $module {
            use super::Category;

            #[test]
            fn every_kind_projects_onto_one_category() {
                let mut counted = 0;

                for discriminant in 0..$count {
                    let kind = <$kind>::of_u16(discriminant)
                        .unwrap_or_else(|| panic!("{discriminant} names a kind"));

                    let category = kind.category();

                    assert!(
                        Category::all().contains(&category),
                        "{} left the category list",
                        kind.name()
                    );

                    assert_eq!(category, kind.category(), "{} reads two ways", kind.name());

                    counted += 1;
                }

                assert_eq!(counted, $count, "a kind went unread");
                assert!(<$kind>::of_u16($count).is_none());
            }

            #[test]
            fn the_projection_reaches_more_than_one_category() {
                let mut seen = 0_u32;

                for discriminant in 0..$count {
                    let kind = <$kind>::of_u16(discriminant)
                        .unwrap_or_else(|| panic!("{discriminant} names a kind"));

                    seen |= 1 << kind.category().index();
                }

                assert!(
                    seen.count_ones() > 1,
                    "the projection collapses every kind onto one category"
                );
            }
        }
    };
}

projection!(
    css,
    scylla::syntax::css::kind::CSSKind,
    scylla::syntax::css::kind::KIND_COUNT
);

projection!(
    go,
    scylla::syntax::go::kind::GoKind,
    scylla::syntax::go::kind::KIND_COUNT
);

projection!(
    javascript,
    scylla::syntax::javascript::kind::JavaScriptKind,
    scylla::syntax::javascript::kind::KIND_COUNT
);

projection!(
    markup,
    scylla::markup::kind::MarkupKind,
    scylla::markup::kind::KIND_COUNT
);

projection!(
    odin,
    scylla::syntax::odin::kind::OdinKind,
    scylla::syntax::odin::kind::KIND_COUNT
);

projection!(
    python,
    scylla::syntax::python::kind::PythonKind,
    scylla::syntax::python::kind::KIND_COUNT
);

projection!(
    rust,
    scylla::syntax::rust::kind::RustKind,
    scylla::syntax::rust::kind::KIND_COUNT
);

projection!(
    typescript,
    scylla::syntax::typescript::kind::TypeScriptKind,
    scylla::syntax::typescript::kind::KIND_COUNT
);

projection!(
    zig,
    scylla::syntax::zig::kind::ZigKind,
    scylla::syntax::zig::kind::KIND_COUNT
);
