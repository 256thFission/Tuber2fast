import importlib.util
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("review_session", ROOT / "DeveloperTools/review-session.py")
review_session = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(review_session)


class ReviewSessionTests(unittest.TestCase):
    def setUp(self):
        self.queue = review_session.load_queue(
            ROOT / "DeveloperTools/ReviewSessions/m0-v2-morning.json"
        )

    def test_repo_queue_is_valid(self):
        review_session.validate(self.queue)

    def test_render_exposes_only_human_fields(self):
        rendered = review_session.render(self.queue, "C3")
        self.assertIn("send this reply", rendered)
        self.assertNotIn("active slot", rendered)
        self.assertNotIn("privately registered", rendered)

    def test_internal_vocabulary_is_rejected(self):
        queue = json.loads(json.dumps(self.queue))
        queue["steps"][0]["human_instruction"] = "Check the sequence cursor."
        with self.assertRaisesRegex(review_session.ValidationError, "internal term"):
            review_session.validate(queue)

    def test_exact_answer_plus_pass_is_rejected(self):
        queue = json.loads(json.dumps(self.queue))
        queue["steps"][0]["human_instruction"] = 'Reply "hello", then report PASS.'
        with self.assertRaisesRegex(review_session.ValidationError, "PASS verdict"):
            review_session.validate(queue)


if __name__ == "__main__":
    unittest.main()
