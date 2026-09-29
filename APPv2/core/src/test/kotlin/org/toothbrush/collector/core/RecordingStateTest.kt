package org.toothbrush.collector.core

import org.junit.Assert.*
import org.junit.Test

class RecordingStateTest {
    private val wall = 1_700_000_000_000L

    @Test fun countdownUsesMonotonicDeadlineAndCannotStartBeforeDue() {
        val state = RecordingState()
        val spec = SessionSpec.create("participant", wall)
        assertTrue(state.arm(spec, wall + 1_200, 40_000))
        assertEquals(Phase.COUNTDOWN, state.phase)
        assertEquals(43_800, state.deadlineElapsedMs)
        assertFalse(state.due(spec.id, 43_799))
        assertFalse(state.started(spec.id))
        assertTrue(state.due(spec.id, 43_800))
        assertEquals(Phase.STARTING, state.phase)
        assertFalse(state.due(spec.id, 44_000))
        assertTrue(state.started(spec.id))
        assertEquals(Phase.RECORDING, state.phase)
        assertFalse(state.started(spec.id))
    }

    @Test fun cancellationPreventsDelayedStartAndReplayOfCancelledIdentity() {
        val state = RecordingState()
        val cancelled = SessionSpec.create("", wall)
        assertTrue(state.arm(cancelled, wall, 100))
        assertTrue(state.stop(cancelled.id))
        assertEquals(Phase.SAVING, state.phase)
        assertFalse(state.due(cancelled.id, 5_100))
        assertFalse(state.started(cancelled.id))
        assertFalse(state.stop(cancelled.id))
        state.saved()
        assertEquals(Phase.IDLE, state.phase)
        // Even if the replay is delivered before the original deadline, it stays cancelled.
        assertFalse(state.arm(cancelled, wall + 1_000, 1_100))
        assertFalse(state.due(cancelled.id, 8_000))
    }

    @Test fun stopBeforeReorderedStartCreatesATombstone() {
        val state = RecordingState()
        val spec = SessionSpec.create("", wall)
        assertFalse(state.stop(spec.id))
        assertFalse(state.arm(spec, wall + 500, 100))
        assertEquals(Phase.IDLE, state.phase)
    }

    @Test fun duplicateAndExpiredStartsDoNotReplaceActiveSession() {
        val state = RecordingState()
        val first = SessionSpec.create("first", wall)
        val second = SessionSpec.create("second", wall)
        assertTrue(state.arm(first, wall, 100))
        assertFalse(state.arm(first, wall + 10, 110))
        assertFalse(state.arm(second, wall + 10, 110))
        assertEquals(first, state.session)
        assertEquals(5_100, state.deadlineElapsedMs)
        val idle = RecordingState()
        assertFalse(idle.arm(second, wall + 5_000, 10_000))
        assertFalse(idle.arm(second, wall + 50_000, 55_000))
        assertFalse(idle.arm(second, wall - 1_001, 10_000))
    }

    @Test fun staleStopAndCallbacksCannotAffectANewSession() {
        val state = RecordingState()
        val old = SessionSpec.create("old", wall)
        assertTrue(state.arm(old, wall, 100))
        assertTrue(state.due(old.id, 5_100))
        assertTrue(state.started(old.id))
        assertTrue(state.stop(old.id))
        state.saved()
        val fresh = SessionSpec.create("new", wall + 10_000)
        assertTrue(state.arm(fresh, wall + 10_000, 10_100))
        assertFalse(state.stop(old.id))
        assertFalse(state.due(old.id, 15_100))
        assertFalse(state.started(old.id))
        assertEquals(Phase.COUNTDOWN, state.phase)
        assertEquals(fresh, state.session)
        assertTrue(state.due(fresh.id, 15_100))
        assertTrue(state.started(fresh.id))
        assertTrue(state.stop(fresh.id))
        state.saved(failed = true)
        assertEquals(Phase.ERROR, state.phase)
        assertFalse(state.active)
        assertTrue(state.arm(SessionSpec.create("after_error", wall + 20_000), wall + 20_000, 20_100))
    }

    @Test fun identityAndSuffixProtectFilesFromCollisionsAndPaths() {
        val first = SessionSpec.create(" ../../subject / watch? ", wall)
        val second = SessionSpec.create(" ../../subject / watch? ", wall)
        assertTrue(first.valid())
        assertEquals("subjectwatch", first.suffix)
        assertEquals(first.stem, second.stem)
        assertNotEquals(first.id, second.id)
        assertEquals(64, sanitizeSuffix("a".repeat(100)).length)
        assertFalse(first.copy(id = "../session").valid())
        assertFalse(first.copy(stem = "../../data").valid())
        assertFalse(first.copy(scheduledEpochMs = first.createdEpochMs).valid())
    }
}
