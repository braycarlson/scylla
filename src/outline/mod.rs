pub mod javascript;
pub mod python;

use crate::structure::{NONE, Node};

pub const SCOPE_DEPTH_MAX: u32 = 64;

pub struct Scopes<'nodes> {
    depth: u32,
    next: u32,
    nodes: &'nodes [Node],
    stack: [u32; SCOPE_DEPTH_MAX as usize],
    token_count: u32,
}

impl<'nodes> Scopes<'nodes> {
    pub fn new(nodes: &'nodes [Node], token_count: u32) -> Self {
        assert!(u32::try_from(nodes.len()).is_ok());

        Self {
            depth: 0,
            next: 0,
            nodes,
            stack: [NONE; SCOPE_DEPTH_MAX as usize],
            token_count,
        }
    }

    pub fn advance(&mut self, token: u32) {
        while (self.next as usize) < self.nodes.len()
            && self.nodes[self.next as usize].token_start <= token
        {
            if self.depth < SCOPE_DEPTH_MAX {
                self.stack[self.depth as usize] = self.next;
                self.depth += 1;
            }

            self.next += 1;
        }

        while self.depth > 0 {
            let index = self.stack[self.depth as usize - 1];

            if self.end_of(index) > token {
                break;
            }

            self.depth -= 1;
        }
    }

    pub fn current(&self) -> u32 {
        if self.depth == 0 {
            return NONE;
        }

        self.stack[self.depth as usize - 1]
    }

    pub fn enclosing(&self, kinds: &[crate::structure::NodeKind]) -> u32 {
        let mut depth = self.depth;

        while depth > 0 {
            depth -= 1;

            let index = self.stack[depth as usize];

            if kinds.contains(&self.nodes[index as usize].kind) {
                return index;
            }
        }

        NONE
    }

    fn end_of(&self, index: u32) -> u32 {
        let node = self.nodes[index as usize];

        if node.token_end == NONE {
            return self.token_count;
        }

        node.token_end
    }
}
