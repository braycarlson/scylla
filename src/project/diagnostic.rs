use crate::bounded::{BoundedVec, count_of};
use crate::diagnostic::{Diagnostic, Diagnostics};
use crate::fix::Fixes;
use crate::project::graph::Graph;
use crate::project::store::{Eviction, FileID, Limits, Store};
use crate::project::view::Sink;
use crate::rule::Registry;

#[expect(
    clippy::struct_field_names,
    reason = "each field is a bound, and `_max` is what every bound in this tree is named"
)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Budget {
    pub arena_bytes_max: u32,
    pub diagnostic_bytes_max: u32,
    pub diagnostic_count_max: u32,
    pub edge_count_max: u32,
    pub edit_count_max: u32,
    pub fix_count_max: u32,
}

pub struct Project {
    budget: Budget,
    diagnostics: Vec<Diagnostics>,
    enrolled: Vec<bool>,
    fixes: Vec<Fixes>,
    generations: Vec<u32>,
    graph: Graph,
    order: BoundedVec<FileID>,
    store: Store,
}

impl Project {
    pub fn reserve(limits: &Limits, eviction: Eviction, budget: &Budget) -> Self {
        assert!(budget.arena_bytes_max > 0);
        assert!(budget.diagnostic_bytes_max > 0);
        assert!(budget.diagnostic_count_max > 0);
        assert!(budget.edge_count_max > 0);
        assert!(budget.edit_count_max > 0);
        assert!(budget.fix_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        let mut diagnostics = Vec::with_capacity(limits.file_count_max as usize);
        let mut fixes = Vec::with_capacity(limits.file_count_max as usize);

        for _ in 0..limits.file_count_max {
            diagnostics.push(Diagnostics::reserve(
                budget.diagnostic_count_max,
                budget.diagnostic_bytes_max,
            ));

            fixes.push(Fixes::reserve(
                budget.fix_count_max,
                budget.edit_count_max,
                budget.arena_bytes_max,
            ));
        }

        assert_eq!(count_of(diagnostics.len()), limits.file_count_max);
        assert_eq!(count_of(fixes.len()), limits.file_count_max);

        Self {
            budget: *budget,
            diagnostics,
            enrolled: vec![false; limits.file_count_max as usize],
            fixes,
            generations: vec![0; limits.file_count_max as usize],
            graph: Graph::reserve(budget.edge_count_max, limits.file_count_max),
            order: BoundedVec::reserve(limits.file_count_max),
            store: Store::reserve(limits, eviction),
        }
    }

    pub const fn budget(&self) -> &Budget {
        &self.budget
    }

    pub fn build(&mut self, resolve: &impl Fn(&[u8], FileID, &Store) -> u32) -> bool {
        self.graph.build(&self.store, resolve)
    }

    pub fn clear(&mut self) {
        for held in &mut self.diagnostics {
            held.clear();
        }

        for held in &mut self.fixes {
            held.clear();
        }

        self.graph.clear();
        self.order.clear();
        self.store.clear();
        self.enrolled.fill(false);

        assert_eq!(self.count(), 0);
    }

    pub fn clear_file(&mut self, file: FileID) {
        let index = file.index() as usize;

        assert!(index < self.diagnostics.len());

        self.diagnostics[index].clear();
        self.fixes[index].clear();

        assert_eq!(self.diagnostics[index].count(), 0);
        assert_eq!(self.fixes[index].count(), 0);
    }

    pub fn count(&self) -> u32 {
        let mut found = 0;

        for held in &self.diagnostics {
            found += held.count();
        }

        found
    }

    pub fn diagnostics_of(&self, file: FileID) -> &Diagnostics {
        &self.diagnostics[file.index() as usize]
    }

    pub fn fixes_of(&self, file: FileID) -> &Fixes {
        &self.fixes[file.index() as usize]
    }

    pub fn fixes_mut(&mut self, file: FileID) -> &mut Fixes {
        &mut self.fixes[file.index() as usize]
    }

    pub fn current(&self) -> bool {
        self.graph.current(&self.store)
    }

    pub fn graph(&self) -> &Graph {
        assert!(
            self.graph.current(&self.store),
            "the store moved a file the graph names"
        );

        &self.graph
    }

    pub fn iter(&self) -> impl Iterator<Item = (FileID, &Diagnostic)> {
        self.order
            .iter()
            .filter(move |file| self.generations[file.index() as usize] == self.stamp_of(**file))
            .flat_map(move |file| {
                self.diagnostics[file.index() as usize]
                    .iter()
                    .map(move |held| (*file, held))
            })
    }

    fn stamp_of(&self, file: FileID) -> u32 {
        self.store.generation_of(file)
    }

    #[must_use]
    pub fn record(&mut self, file: FileID, diagnostic: Diagnostic) -> bool {
        let index = file.index() as usize;

        assert!(index < self.diagnostics.len());

        if !self.enrol(file) {
            return false;
        }

        self.diagnostics[index].push(diagnostic)
    }

    pub fn sink<'run>(&'run mut self, file: FileID, registry: &'run Registry) -> Sink<'run> {
        let index = file.index() as usize;

        assert!(index < self.diagnostics.len());

        let enrolled = self.enrol(file);

        assert!(enrolled);

        Sink::new(file, &mut self.diagnostics[index], registry)
    }

    pub fn sort(&mut self) {
        let Self {
            diagnostics,
            order,

            store,
            ..
        } = self;

        for file in order.iter() {
            diagnostics[file.index() as usize].sort();
        }

        order.sort_unstable_by_key(|file| sequence_of(store, *file));

        assert!(order.count() <= order.capacity());
    }

    pub const fn store(&self) -> &Store {
        &self.store
    }

    pub const fn store_mut(&mut self) -> &mut Store {
        &mut self.store
    }

    fn enrol(&mut self, file: FileID) -> bool {
        let index = file.index() as usize;

        assert!(index < self.enrolled.len());

        if self.enrolled[index] {
            return true;
        }

        self.generations[index] = self.store.generation_of(file);

        let pushed = self.order.push(file);

        self.enrolled[index] = pushed;

        pushed
    }
}

fn sequence_of(store: &Store, file: FileID) -> u64 {
    if !store.resident(file) {
        return u64::MAX;
    }

    store.sequence_of(file)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bounded::{Buffer, Span};
    use crate::diagnostic::Severity;
    use crate::fix::{self, Applicability, NONE as FIX_NONE};
    use crate::language::Language;
    use crate::project::store::{CLASS_COUNT, NONE, hash_of};
    use crate::rule::Rule;
    use crate::syntax::front;

    const ALPHA: &[u8] = b"first = 1\nsecond = 2\n";
    const BETA: &[u8] = b"third = 3\n";
    const GAMMA: &[u8] = b"fourth = 4\n";

    static RULES: [Rule; 1] = [Rule {
        citation_nasa: "",
        citation_tigerstyle: "",
        default_on: true,
        description: "",
        code: "B002",
        explanation: "The sink test records one row so the file it lands in can be read.",
        fix_title: "",
        fixable: crate::rule::Fixable::Never,
        name: "sink-probe",
        preview: false,
        severity: Severity::Error,
        summary: "Sink probe",
        url: "",
    }];

    fn budget_of() -> Budget {
        Budget {
            arena_bytes_max: 1_024,
            diagnostic_bytes_max: 4_096,
            diagnostic_count_max: 32,
            edge_count_max: 32,
            edit_count_max: 32,
            fix_count_max: 16,
        }
    }

    fn limits_of(file_count_max: u32) -> Limits {
        let mut slots = [[0_u32; CLASS_COUNT]; Language::COUNT];

        slots[Language::Python.index()][Limits::class_of(1_024) as usize] = file_count_max;

        Limits {
            file_count_max,
            front: front::Limits {
                binding_count_max: 128,
                error_count_max: 32,
                event_count_max: 2_048,
                export_count_max: 128,
                fact_count_max: 128,
                node_count_max: 1_024,
                reference_count_max: 128,
                scope_count_max: 32,
                segment_count_max: 128,
                token_count_max: 512,
            },
            line_count_max: 128,
            slots,
            source_bytes_max: 1_024,
        }
    }

    fn row(code: &'static str, offset: u32) -> Diagnostic {
        Diagnostic {
            code,
            fix: FIX_NONE,
            message: crate::diagnostic::Message::Static("a recorded finding"),
            related_count: 0,
            related_start: 0,
            rule: crate::rule::NONE,
            severity: Severity::Warning,
            span: Span { length: 1, offset },
        }
    }

    fn project_of() -> (Project, [FileID; 3]) {
        let limits = limits_of(3);
        let mut project = Project::reserve(&limits, Eviction::Reject, &budget_of());

        let alpha = project
            .store_mut()
            .insert(hash_of(b"alpha"), Language::Python, ALPHA);

        let beta = project
            .store_mut()
            .insert(hash_of(b"beta"), Language::Python, BETA);

        let gamma = project
            .store_mut()
            .insert(hash_of(b"gamma"), Language::Python, GAMMA);

        assert!(alpha != NONE);
        assert!(beta != NONE);
        assert!(gamma != NONE);

        (
            project,
            [FileID::of(alpha), FileID::of(beta), FileID::of(gamma)],
        )
    }

    fn report_of(project: &Project) -> Vec<(u32, &'static str, u32)> {
        project
            .iter()
            .map(|(file, held)| (file.index(), held.code, held.span.offset))
            .collect()
    }

    fn recorded(project: &mut Project, files: [FileID; 3]) {
        assert!(project.record(files[2], row("C001", 3)));
        assert!(project.record(files[0], row("A002", 7)));
        assert!(project.record(files[0], row("A001", 7)));
        assert!(project.record(files[1], row("B001", 5)));
        assert!(project.record(files[0], row("A003", 1)));
    }

    #[test]
    fn a_slot_that_takes_another_file_drops_the_graph_and_the_rows_the_first_one_left() {
        for eviction in [Eviction::LeastRecentlyUsed, Eviction::Reject] {
            let limits = limits_of(1);
            let mut project = Project::reserve(&limits, eviction, &budget_of());

            let held = project
                .store_mut()
                .insert(hash_of(b"alpha"), Language::Python, ALPHA);

            assert!(held != NONE);

            let file = FileID::of(held);

            assert!(project.build(&|_, _, _| NONE));
            assert!(project.record(file, row("A001", 1)));
            assert_eq!(report_of(&project).len(), 1);
            assert!(project.current());

            let generation = project.store().generation_of(file);

            project.store_mut().evict(file);

            let second = project
                .store_mut()
                .insert(hash_of(b"beta"), Language::Python, BETA);

            assert_eq!(second, held);
            assert_ne!(project.store().generation_of(file), generation);
            assert!(!project.current());
            assert_eq!(report_of(&project).len(), 0);
        }
    }

    #[test]
    #[should_panic(expected = "the store moved a file the graph names")]
    fn a_graph_read_after_the_slot_moved_trips_its_own_assertion() {
        let limits = limits_of(1);
        let mut project = Project::reserve(&limits, Eviction::Reject, &budget_of());

        let held = project
            .store_mut()
            .insert(hash_of(b"alpha"), Language::Python, ALPHA);

        assert!(held != NONE);
        assert!(project.build(&|_, _, _| NONE));

        let file = FileID::of(held);

        project.store_mut().evict(file);

        let second = project
            .store_mut()
            .insert(hash_of(b"beta"), Language::Python, BETA);

        assert_eq!(second, held);

        let _ = project.graph().order();
    }

    #[test]
    fn a_slot_reads_back_the_path_hash_it_was_inserted_under() {
        let (project, files) = project_of();

        assert_eq!(project.store().path_hash_of(files[0]), hash_of(b"alpha"));
        assert_eq!(project.store().path_hash_of(files[1]), hash_of(b"beta"));
    }

    #[test]
    fn a_sorted_report_orders_by_file_then_offset_then_code() {
        let (mut project, files) = project_of();

        recorded(&mut project, files);
        project.sort();

        assert_eq!(project.count(), 5);

        assert_eq!(
            report_of(&project),
            vec![
                (files[0].index(), "A003", 1),
                (files[0].index(), "A001", 7),
                (files[0].index(), "A002", 7),
                (files[1].index(), "B001", 5),
                (files[2].index(), "C001", 3),
            ]
        );
    }

    #[test]
    fn clearing_one_file_leaves_the_others() {
        let (mut project, files) = project_of();

        recorded(&mut project, files);
        project.clear_file(files[0]);
        project.sort();

        assert_eq!(project.count(), 2);

        assert_eq!(
            report_of(&project),
            vec![(files[1].index(), "B001", 5), (files[2].index(), "C001", 3)]
        );
    }

    #[test]
    fn a_fix_applies_to_its_own_file_alone() {
        let (mut project, files) = project_of();

        project
            .fixes_mut(files[0])
            .open("rename", Applicability::Safe, 0);

        let edited = project.fixes_mut(files[0]).edit(
            Span {
                length: 5,
                offset: 0,
            },
            b"third",
        );

        assert!(edited);

        let index = project.fixes_mut(files[0]).close();

        assert!(index != FIX_NONE);
        assert_eq!(project.fixes_of(files[1]).count(), 0);

        let table = project.fixes_of(files[0]);
        let held = table.get(index).expect("the fix is recorded");
        let mut out = Buffer::reserve(1_024);

        assert!(fix::apply(
            project.store().source_of(files[0]),
            table,
            table.edits_of(held),
            &mut out
        ));

        assert_eq!(out.as_bytes(), b"third = 1\nsecond = 2\n");
        assert_eq!(project.store().source_of(files[1]), BETA);
    }

    #[test]
    fn the_same_recording_reports_the_same_bytes_twice() {
        let (mut first, files) = project_of();

        recorded(&mut first, files);
        first.sort();

        let (mut second, again) = project_of();

        recorded(&mut second, again);
        second.sort();

        assert_eq!(report_of(&first), report_of(&second));
        assert_eq!(files, again);
    }

    #[test]
    fn a_sink_writes_into_the_file_it_names() {
        let (mut project, files) = project_of();

        {
            let registry = Registry::reserve(&RULES);
            let mut sink = project.sink(files[1], &registry);

            assert!(sink.record(
                "B002",
                Severity::Error,
                Span {
                    length: 1,
                    offset: 2
                },
                "a recorded finding"
            ));
        }

        project.sort();

        assert_eq!(project.count(), 1);
        assert_eq!(report_of(&project), vec![(files[1].index(), "B002", 2)]);
    }
}
