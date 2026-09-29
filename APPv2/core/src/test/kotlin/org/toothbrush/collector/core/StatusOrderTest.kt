package org.toothbrush.collector.core

import org.junit.Assert.*
import org.junit.Test

class StatusOrderTest {
    @Test fun reorderedAndDuplicateStatusCannotRollBackCurrentState() {
        val order = StatusOrder()
        assertTrue(order.accept("watch", "process-A", 1))
        assertTrue(order.accept("watch", "process-A", 4))
        assertFalse(order.accept("watch", "process-A", 2))
        assertFalse(order.accept("watch", "process-A", 4))
        assertTrue(order.accept("watch", "process-A", 5))
    }

    @Test fun replacementProcessCanRestartSequenceButRetiredProcessCannotReturn() {
        val order = StatusOrder()
        assertTrue(order.accept("watch", "process-A", 800))
        assertTrue(order.accept("watch", "process-B", 1))
        assertFalse(order.accept("watch", "process-A", 801))
        assertTrue(order.accept("watch", "process-B", 2))
        assertTrue(order.accept("watch", "process-C", 1))
        assertFalse(order.accept("watch", "process-A", 9_000))
        assertFalse(order.accept("watch", "process-B", 9_000))
        assertTrue(order.accept("watch", "process-C", 2))
    }

    @Test fun peersHaveIndependentSequencesAndRetirementHistory() {
        val order = StatusOrder()
        assertTrue(order.accept("watch-one", "process-A", 50))
        assertTrue(order.accept("watch-two", "process-A", 1))
        assertTrue(order.accept("watch-one", "process-B", 1))
        assertFalse(order.accept("watch-one", "process-A", 51))
        assertTrue(order.accept("watch-two", "process-A", 2))
    }

    @Test fun invalidMessagesDoNotCreateOrReplaceACursor() {
        val order = StatusOrder()
        assertFalse(order.accept("watch", "process-A", 0))
        assertFalse(order.accept("watch", "process-A", -1))
        assertFalse(order.accept("watch", " ", 1))
        assertTrue(order.accept("watch", "process-A", 1))
        assertFalse(order.accept("watch", "process-B", 0))
        assertTrue(order.accept("watch", "process-A", 2))
        assertTrue(order.accept("watch", "process-A", Long.MAX_VALUE))
        assertFalse(order.accept("watch", "process-A", Long.MIN_VALUE))
    }
    @Test fun delayedUnknownOldProcessCannotRetireTheCurrentProcess() {
        val order = StatusOrder()
        assertTrue(order.accept("watch", "installation", 3, 2))
        assertFalse(order.accept("watch", "installation", 999, 1))
        assertTrue(order.accept("watch", "installation", 1, 3))
        assertFalse(order.accept("watch", "installation", 4, 2))
        assertTrue(order.accept("watch", "installation", 2, 3))
    }
}
