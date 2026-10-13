"""Focused source regression guard for CFStream teardown ordering."""

from pathlib import Path
import unittest


SOURCE = Path(__file__).parents[1] / "Sources" / "GCDAsyncSocket.m"


class GCDAsyncSocketStreamTeardownTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text()
        start = cls.source.index("- (void)closeWithError:")
        cls.close = cls.source[start:cls.source.index("- (void)disconnect", start)]
        helper_start = cls.source.rindex("- (void)closeStreams")
        cls.helper = cls.source[helper_start:cls.source.index("- (BOOL)openStreams", helper_start)]

    def test_both_streams_close_before_either_is_released(self):
        self.assertLess(self.helper.index("CFReadStreamClose"), self.helper.index("CFWriteStreamClose"))
        self.assertLess(self.helper.index("CFWriteStreamClose"), self.helper.index("CFRelease(readStream)"))
        self.assertLess(self.helper.index("CFRelease(readStream)"), self.helper.index("CFRelease(writeStream)"))

    def test_close_is_marshaled_to_the_cfstream_thread(self):
        self.assertIn("[self performSelector:@selector(closeStreams)", self.close)
        self.assertNotIn("[[self class] performSelector:@selector(closeStreams)", self.close)
        self.assertIn("kStreamsTeardownStarted", self.close)
        self.assertIn("flags |= kStreamsTeardownStarted", self.close)
        self.assertIn("if (!(flags & kStreamsTeardownStarted))", self.close)
        self.assertIn("CFReadStreamUnscheduleFromRunLoop", self.helper)
        self.assertIn("CFWriteStreamUnscheduleFromRunLoop", self.helper)
        self.assertIn("CFReadStreamSetClient", self.helper)
        self.assertIn("CFWriteStreamSetClient", self.helper)

    def test_callbacks_are_disabled_after_unscheduling(self):
        self.assertLess(self.helper.index("CFReadStreamSetClient"), self.helper.index("CFReadStreamClose"))
        self.assertLess(self.helper.index("CFWriteStreamSetClient"), self.helper.index("CFWriteStreamClose"))

    def test_teardown_helper_is_idempotent_after_owners_are_released(self):
        empty_guard = self.helper.index("if (!readStream && !writeStream)")
        first_release = self.helper.index("CFRelease(readStream)")
        self.assertLess(empty_guard, first_release)
        self.assertIn("flags &= ~kAddedStreamsToRunLoop", self.close)
        self.assertNotIn("flags &= ~kAddedStreamsToRunLoop", self.helper)

    def test_partial_creation_path_uses_the_same_close_before_release_order(self):
        start = self.source.index("if ((readStream == NULL) || (writeStream == NULL))")
        partial = self.source[start:self.source.index("return NO;", start)]
        self.assertLess(partial.index("CFReadStreamClose"), partial.index("CFWriteStreamClose"))
        self.assertLess(partial.index("CFWriteStreamClose"), partial.index("CFRelease(readStream)"))
        self.assertLess(partial.index("CFRelease(readStream)"), partial.index("CFRelease(writeStream)"))


if __name__ == "__main__":
    unittest.main()
