use std::fs;
use std::path::{Path, PathBuf};

use syn::spanned::Spanned;
use syn::visit::Visit;

struct Walker {
    columns: Vec<Vec<usize>>,
    length: usize,
    rows: Vec<(&'static str, usize, usize)>,
}

impl Walker {
    fn offset_of(&self, place: proc_macro2::LineColumn) -> usize {
        let Some(row) = self.columns.get(place.line.saturating_sub(1)) else {
            return self.length;
        };

        row.get(place.column)
            .copied()
            .unwrap_or_else(|| row.last().copied().unwrap_or(self.length))
    }

    fn push(&mut self, name: &'static str, span: proc_macro2::Span) {
        let start = self.offset_of(span.start());
        let end = self.offset_of(span.end());

        if end < start {
            return;
        }

        self.rows.push((name, start, end));
    }
}

macro_rules! record {
    ($($method:ident => $held:ty, $name:expr;)*) => {
        $(
            fn $method(&mut self, node: &'ast $held) {
                self.push($name, node.span());
                syn::visit::$method(self, node);
            }
        )*
    };
}

impl<'ast> Visit<'ast> for Walker {
    fn visit_ident(&mut self, node: &'ast proc_macro2::Ident) {
        self.push("Ident", node.span());
    }

    record! {
        visit_abi => syn::Abi, "Abi";
        visit_arm => syn::Arm, "Arm";
        visit_assoc_const => syn::AssocConst, "AssocConst";
        visit_assoc_type => syn::AssocType, "AssocType";
        visit_attribute => syn::Attribute, "Attribute";
        visit_bare_fn_arg => syn::BareFnArg, "BareFnArg";
        visit_bare_variadic => syn::BareVariadic, "BareVariadic";
        visit_block => syn::Block, "Block";
        visit_bound_lifetimes => syn::BoundLifetimes, "BoundLifetimes";
        visit_const_param => syn::ConstParam, "ConstParam";
        visit_constraint => syn::Constraint, "Constraint";
        visit_expr_array => syn::ExprArray, "ExprArray";
        visit_expr_assign => syn::ExprAssign, "ExprAssign";
        visit_expr_async => syn::ExprAsync, "ExprAsync";
        visit_expr_await => syn::ExprAwait, "ExprAwait";
        visit_expr_binary => syn::ExprBinary, "ExprBinary";
        visit_expr_block => syn::ExprBlock, "ExprBlock";
        visit_expr_break => syn::ExprBreak, "ExprBreak";
        visit_expr_call => syn::ExprCall, "ExprCall";
        visit_expr_cast => syn::ExprCast, "ExprCast";
        visit_expr_closure => syn::ExprClosure, "ExprClosure";
        visit_expr_const => syn::ExprConst, "ExprConst";
        visit_expr_continue => syn::ExprContinue, "ExprContinue";
        visit_expr_field => syn::ExprField, "ExprField";
        visit_expr_for_loop => syn::ExprForLoop, "ExprForLoop";
        visit_expr_group => syn::ExprGroup, "ExprGroup";
        visit_expr_if => syn::ExprIf, "ExprIf";
        visit_expr_index => syn::ExprIndex, "ExprIndex";
        visit_expr_infer => syn::ExprInfer, "ExprInfer";
        visit_expr_let => syn::ExprLet, "ExprLet";
        visit_expr_lit => syn::ExprLit, "ExprLit";
        visit_expr_loop => syn::ExprLoop, "ExprLoop";
        visit_expr_macro => syn::ExprMacro, "ExprMacro";
        visit_expr_match => syn::ExprMatch, "ExprMatch";
        visit_expr_method_call => syn::ExprMethodCall, "ExprMethodCall";
        visit_expr_paren => syn::ExprParen, "ExprParen";
        visit_expr_path => syn::ExprPath, "ExprPath";
        visit_expr_range => syn::ExprRange, "ExprRange";
        visit_expr_raw_addr => syn::ExprRawAddr, "ExprRawAddr";
        visit_expr_reference => syn::ExprReference, "ExprReference";
        visit_expr_repeat => syn::ExprRepeat, "ExprRepeat";
        visit_expr_return => syn::ExprReturn, "ExprReturn";
        visit_expr_struct => syn::ExprStruct, "ExprStruct";
        visit_expr_try => syn::ExprTry, "ExprTry";
        visit_expr_try_block => syn::ExprTryBlock, "ExprTryBlock";
        visit_expr_tuple => syn::ExprTuple, "ExprTuple";
        visit_expr_unary => syn::ExprUnary, "ExprUnary";
        visit_expr_unsafe => syn::ExprUnsafe, "ExprUnsafe";
        visit_expr_while => syn::ExprWhile, "ExprWhile";
        visit_expr_yield => syn::ExprYield, "ExprYield";
        visit_field => syn::Field, "Field";
        visit_field_pat => syn::FieldPat, "FieldPat";
        visit_field_value => syn::FieldValue, "FieldValue";
        visit_fields_named => syn::FieldsNamed, "FieldsNamed";
        visit_fields_unnamed => syn::FieldsUnnamed, "FieldsUnnamed";
        visit_foreign_item_fn => syn::ForeignItemFn, "ForeignItemFn";
        visit_foreign_item_macro => syn::ForeignItemMacro, "ForeignItemMacro";
        visit_foreign_item_static => syn::ForeignItemStatic, "ForeignItemStatic";
        visit_foreign_item_type => syn::ForeignItemType, "ForeignItemType";
        visit_generics => syn::Generics, "Generics";
        visit_impl_item_const => syn::ImplItemConst, "ImplItemConst";
        visit_impl_item_fn => syn::ImplItemFn, "ImplItemFn";
        visit_impl_item_macro => syn::ImplItemMacro, "ImplItemMacro";
        visit_impl_item_type => syn::ImplItemType, "ImplItemType";
        visit_index => syn::Index, "Index";
        visit_item_const => syn::ItemConst, "ItemConst";
        visit_item_enum => syn::ItemEnum, "ItemEnum";
        visit_item_extern_crate => syn::ItemExternCrate, "ItemExternCrate";
        visit_item_fn => syn::ItemFn, "ItemFn";
        visit_item_foreign_mod => syn::ItemForeignMod, "ItemForeignMod";
        visit_item_impl => syn::ItemImpl, "ItemImpl";
        visit_item_macro => syn::ItemMacro, "ItemMacro";
        visit_item_mod => syn::ItemMod, "ItemMod";
        visit_item_static => syn::ItemStatic, "ItemStatic";
        visit_item_struct => syn::ItemStruct, "ItemStruct";
        visit_item_trait => syn::ItemTrait, "ItemTrait";
        visit_item_trait_alias => syn::ItemTraitAlias, "ItemTraitAlias";
        visit_item_type => syn::ItemType, "ItemType";
        visit_item_union => syn::ItemUnion, "ItemUnion";
        visit_item_use => syn::ItemUse, "ItemUse";
        visit_label => syn::Label, "Label";
        visit_lifetime => syn::Lifetime, "Lifetime";
        visit_lifetime_param => syn::LifetimeParam, "LifetimeParam";
        visit_lit_bool => syn::LitBool, "LitBool";
        visit_lit_byte => syn::LitByte, "LitByte";
        visit_lit_byte_str => syn::LitByteStr, "LitByteStr";
        visit_lit_cstr => syn::LitCStr, "LitCStr";
        visit_lit_char => syn::LitChar, "LitChar";
        visit_lit_float => syn::LitFloat, "LitFloat";
        visit_lit_int => syn::LitInt, "LitInt";
        visit_lit_str => syn::LitStr, "LitStr";
        visit_local => syn::Local, "Local";
        visit_macro => syn::Macro, "Macro";
        visit_meta_list => syn::MetaList, "MetaList";
        visit_meta_name_value => syn::MetaNameValue, "MetaNameValue";
        visit_pat_ident => syn::PatIdent, "PatIdent";
        visit_pat_or => syn::PatOr, "PatOr";
        visit_pat_paren => syn::PatParen, "PatParen";
        visit_pat_reference => syn::PatReference, "PatReference";
        visit_pat_rest => syn::PatRest, "PatRest";
        visit_pat_slice => syn::PatSlice, "PatSlice";
        visit_pat_struct => syn::PatStruct, "PatStruct";
        visit_pat_tuple => syn::PatTuple, "PatTuple";
        visit_pat_tuple_struct => syn::PatTupleStruct, "PatTupleStruct";
        visit_pat_type => syn::PatType, "PatType";
        visit_pat_wild => syn::PatWild, "PatWild";
        visit_path => syn::Path, "Path";
        visit_path_segment => syn::PathSegment, "PathSegment";
        visit_precise_capture => syn::PreciseCapture, "PreciseCapture";
        visit_predicate_lifetime => syn::PredicateLifetime, "PredicateLifetime";
        visit_predicate_type => syn::PredicateType, "PredicateType";
        visit_receiver => syn::Receiver, "Receiver";
        visit_signature => syn::Signature, "Signature";
        visit_stmt_macro => syn::StmtMacro, "StmtMacro";
        visit_trait_bound => syn::TraitBound, "TraitBound";
        visit_trait_item_const => syn::TraitItemConst, "TraitItemConst";
        visit_trait_item_fn => syn::TraitItemFn, "TraitItemFn";
        visit_trait_item_macro => syn::TraitItemMacro, "TraitItemMacro";
        visit_trait_item_type => syn::TraitItemType, "TraitItemType";
        visit_type_array => syn::TypeArray, "TypeArray";
        visit_type_bare_fn => syn::TypeBareFn, "TypeBareFn";
        visit_type_group => syn::TypeGroup, "TypeGroup";
        visit_type_impl_trait => syn::TypeImplTrait, "TypeImplTrait";
        visit_type_infer => syn::TypeInfer, "TypeInfer";
        visit_type_macro => syn::TypeMacro, "TypeMacro";
        visit_type_never => syn::TypeNever, "TypeNever";
        visit_type_param => syn::TypeParam, "TypeParam";
        visit_type_paren => syn::TypeParen, "TypeParen";
        visit_type_path => syn::TypePath, "TypePath";
        visit_type_ptr => syn::TypePtr, "TypePtr";
        visit_type_reference => syn::TypeReference, "TypeReference";
        visit_type_slice => syn::TypeSlice, "TypeSlice";
        visit_type_trait_object => syn::TypeTraitObject, "TypeTraitObject";
        visit_type_tuple => syn::TypeTuple, "TypeTuple";
        visit_use_glob => syn::UseGlob, "UseGlob";
        visit_use_group => syn::UseGroup, "UseGroup";
        visit_use_name => syn::UseName, "UseName";
        visit_use_path => syn::UsePath, "UsePath";
        visit_use_rename => syn::UseRename, "UseRename";
        visit_variadic => syn::Variadic, "Variadic";
        visit_variant => syn::Variant, "Variant";
        visit_vis_restricted => syn::VisRestricted, "VisRestricted";
        visit_where_clause => syn::WhereClause, "WhereClause";
    }
}

fn escape(text: &str) -> String {
    let mut found = String::new();

    for held in text.chars() {
        match held {
            '"' => found.push_str("\\\""),
            '\\' => found.push_str("\\\\"),
            '\n' => found.push_str("\\n"),
            '\r' => found.push_str("\\r"),
            '\t' => found.push_str("\\t"),
            _ => found.push(held),
        }
    }

    found
}

fn line_starts(text: &str) -> Vec<usize> {
    let mut starts = vec![0_usize];
    let bytes = text.as_bytes();
    let mut offset = 0;

    while offset < bytes.len() {
        if bytes[offset] == b'\n' {
            starts.push(offset + 1);
        }

        offset += 1;
    }

    starts
}

fn char_columns(text: &str, starts: &[usize]) -> Vec<Vec<usize>> {
    let mut found = Vec::new();

    for (index, start) in starts.iter().enumerate() {
        let end = starts.get(index + 1).copied().unwrap_or(text.len());
        let mut columns = Vec::new();
        let mut offset = *start;

        loop {
            columns.push(offset);

            if offset >= end {
                break;
            }

            let mut width = 1;

            while offset + width < text.len() && !text.is_char_boundary(offset + width) {
                width += 1;
            }

            offset += width;
        }

        found.push(columns);
    }

    found
}

fn sources(root: &Path) -> Vec<(String, PathBuf)> {
    let mut found = Vec::new();
    let mut stack = vec![root.to_path_buf()];

    while let Some(current) = stack.pop() {
        let Ok(entries) = fs::read_dir(&current) else {
            continue;
        };

        for entry in entries.flatten() {
            let path = entry.path();

            if path.is_dir() {
                stack.push(path);

                continue;
            }

            if path.extension().and_then(|held| held.to_str()) != Some("rs") {
                continue;
            }

            let relative = path
                .strip_prefix(root)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");

            found.push((relative, path));
        }
    }

    found.sort();

    found
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let arguments: Vec<String> = std::env::args().collect();

    if arguments.len() != 3 {
        eprintln!("usage: oracle-syn <source root> <destination root>");

        std::process::exit(2);
    }

    let root = PathBuf::from(&arguments[1]);
    let destination = PathBuf::from(&arguments[2]);
    let mut skipped = Vec::new();

    for (relative, path) in sources(&root) {
        let Ok(text) = fs::read_to_string(&path) else {
            skipped.push((relative, "Utf8"));

            continue;
        };

        let parsed = match syn::parse_file(&text) {
            Ok(held) => held,
            Err(_) => {
                skipped.push((relative, "Syntax"));

                continue;
            }
        };

        let starts = line_starts(&text);

        let mut walker = Walker {
            columns: char_columns(&text, &starts),
            length: text.len(),
            rows: Vec::new(),
        };

        walker.visit_file(&parsed);

        let mut body = String::from("{\"ast\":[");

        body.push_str(&format!("[\"File\",0,{}]", text.len()));

        for (name, start, end) in &walker.rows {
            body.push_str(&format!(",[\"{}\",{},{}]", escape(name), start, end));
        }

        body.push_str(&format!(
            "],\"broken\":false,\"path\":\"{}\"}}\n",
            escape(&relative)
        ));

        let target = destination.join(format!("{relative}.json"));

        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }

        fs::write(&target, body)?;
    }

    for (relative, reason) in &skipped {
        eprintln!("skipped {relative} ({reason})");
    }

    Ok(())
}
