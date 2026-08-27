use crate::bounded::count_of;
use crate::fuzzing::{Applied, LineModel, MODEL_LINE_COUNT_MAX};
use crate::lines::{Encoding, Index};

const HEADER_BYTES: usize = 6;

pub struct EditHarness {
    index: Index,
    model: LineModel,
    rebuilt: Index,
}

impl EditHarness {
    pub fn reserve() -> Self {
        assert!(!crate::allocation::is_frozen());

        let held = Self {
            index: Index::reserve(count_of(MODEL_LINE_COUNT_MAX)),
            model: LineModel::reserve(),
            rebuilt: Index::reserve(count_of(MODEL_LINE_COUNT_MAX)),
        };

        assert_eq!(held.index.capacity(), held.rebuilt.capacity());

        held
    }

    pub fn check(&mut self, data: &[u8]) {
        assert!(self.index.capacity() >= count_of(MODEL_LINE_COUNT_MAX));
        assert!(self.rebuilt.capacity() >= count_of(MODEL_LINE_COUNT_MAX));

        self.model.clear();
        self.index.clear();

        let mut cursor = 0;

        while cursor + HEADER_BYTES <= data.len() {
            let selector = data[cursor];
            let start_raw = u32::from(u16::from_le_bytes([data[cursor + 1], data[cursor + 2]]));
            let end_raw = u32::from(u16::from_le_bytes([data[cursor + 3], data[cursor + 4]]));
            let take = data[cursor + 5] as usize;

            cursor += HEADER_BYTES;

            let stop = (cursor + take).min(data.len());
            let insertion = &data[cursor..stop];

            cursor = stop;

            self.step(selector, start_raw, end_raw, insertion);
            self.agree();
            self.positions_hold();
        }
    }

    fn step(&mut self, selector: u8, start_raw: u32, end_raw: u32, insertion: &[u8]) {
        let length = count_of(self.model.length());

        assert!(length as usize <= crate::fuzzing::MODEL_BYTES_MAX);

        if selector & 1 == 0 {
            let _ = self.model.replaced(insertion);
            let built = self.index.build(self.model.as_bytes());

            assert!(built, "a replacement outgrew the index capacity");

            return;
        }

        let first = self.model.boundary_at(start_raw % (length + 1));
        let second = self.model.boundary_at(end_raw % (length + 1));
        let start = first.min(second);
        let end = first.max(second);

        match self.model.spliced(start, end, insertion) {
            Applied::Accepted => {
                let plan = self
                    .index
                    .splice_plan(start, end, insertion)
                    .expect("the model accepted a splice the index refuses");

                self.index.splice_apply(start, end, insertion, &plan);
            }
            Applied::RefusedLines => {
                let built = self.index.build(self.model.as_bytes());

                assert!(built, "a cleared model outgrew the index capacity");
            }
            Applied::RefusedSize | Applied::RefusedUtf8 => {}
        }
    }

    fn agree(&mut self) {
        let length = count_of(self.model.length());
        let built = self.rebuilt.build(self.model.as_bytes());

        assert!(built, "the model text outgrew the rebuild capacity");

        self.index.validate(length);

        let count = self.rebuilt.count();

        assert_eq!(
            self.index.count(),
            count,
            "an incremental splice and a full rebuild disagree on the line count"
        );

        assert_eq!(
            count as usize,
            self.model.line_count(),
            "the index and the model disagree on the line count"
        );

        for line in 0..count {
            assert_eq!(
                self.index.line_start(line),
                self.rebuilt.line_start(line),
                "an incremental splice and a full rebuild disagree on line {line}"
            );

            assert_eq!(
                self.index.line_start(line),
                self.model.line_start(line),
                "the index and the model disagree on the start of line {line}"
            );

            assert_eq!(
                self.index.line_end(line, length),
                self.model.line_end(line),
                "the index and the model disagree on the end of line {line}"
            );
        }
    }

    fn positions_hold(&self) {
        let text = self.model.as_str();

        assert!(text.len() <= crate::fuzzing::MODEL_BYTES_MAX);
        assert_eq!(self.index.count() as usize, self.model.line_count());

        for line in 0..count_of(self.model.line_count()) {
            let start = self.model.line_start(line);
            let end = self.model.line_end(line);
            let middle = self.model.boundary_at(start + (end - start) / 2);

            for offset in [start, middle, self.model.boundary_at(end)] {
                for encoding in [Encoding::Utf16, Encoding::Utf8] {
                    position_agrees(&self.model, &self.index, text, offset, encoding);
                }
            }
        }
    }
}

fn position_agrees(model: &LineModel, index: &Index, text: &str, offset: u32, encoding: Encoding) {
    let held = model.position_in(offset, encoding);
    let theirs = index.position_of(text, offset, encoding);

    assert_eq!(
        held, theirs,
        "the index and the model disagree on the position of offset {offset}"
    );

    let offset_model = model.offset_in(held, encoding);
    let offset_index = index.offset_of(text, held, encoding);

    assert_eq!(
        offset_model, offset_index,
        "the index and the model disagree on the offset of {held:?}"
    );

    assert_eq!(
        offset_model,
        Some(offset),
        "a position round trip does not return to offset {offset}"
    );
}
