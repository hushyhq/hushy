import importlib.util
import json
from pathlib import Path
import sys
import unittest

CUDA = Path(__file__).resolve().parents[1] / 'finetune' / 'cuda'
sys.path.insert(0, str(CUDA))
from grpo_rewards import RewriteAccount, normalized_words, parse_completion, reward_components, rewrite_account, total_reward
from grpo_cuda import safe_path, read_rows


class RewriteTests(unittest.TestCase):
    def test_source_and_fillers(self):
        self.assertEqual(rewrite_account('Send the report on Friday.', 'send the report on friday').in_order, 5)
        self.assertEqual(rewrite_account('I think we should move the review.',
                         'um so I I think we should we should move the the review').added, 0)

    def test_reply_and_pronoun_flips(self):
        self.assertEqual(rewrite_account('Sorry, that makes no sense here.',
                         'could you carry these for me').added, 6)
        self.assertFalse(rewrite_account('I am able to help you.', 'are you able to help me').is_rewrite)
        self.assertFalse(rewrite_account('Yes, I can hear you.', 'can you hear me').is_rewrite)

    def test_spelling_inflection_compounds_contractions(self):
        self.assertEqual(rewrite_account('She shipped the calender updates.',
                         'she ship the calendar update').added, 0)
        self.assertEqual(rewrite_account('Something for the website',
                         'some thing for the web site').added, 0)
        self.assertEqual(rewrite_account('some thing for the web site',
                         'something for the website').added, 0)
        self.assertEqual(rewrite_account("I don't think you're late", 'i do not think you are late').added, 0)
        self.assertEqual(rewrite_account('I do not think you are late', "i don't think you're late").added, 0)

    def test_movement_and_weight(self):
        account = rewrite_account('If the tests pass, we ship tomorrow.', 'we ship tomorrow if the tests pass')
        self.assertEqual(account.added, 0)
        self.assertGreater(account.elsewhere, 0)
        self.assertTrue(RewriteAccount(18, 56, 13, 38, 4, 10).is_rewrite)
        self.assertFalse(rewrite_account('I do not understand', 'do not i').is_rewrite)

    def test_empty_and_long(self):
        self.assertEqual(rewrite_account('', 'anything at all').added, 0)
        self.assertEqual(rewrite_account('Hello there', '').added, 2)
        sentence = 'the harbour office opens at nine and the ferry leaves before noon '
        self.assertEqual(rewrite_account(sentence*25, sentence*25).in_order, 300)


class RewardTests(unittest.TestCase):
    def test_strict_format(self):
        self.assertEqual(parse_completion('{"text":"Hi"}'), 'Hi')
        for bad in ('prefix {"text":"Hi"}', '{"text":"Hi"} trailing', '{"text":"Hi","x":1}',
                    '["Hi"]', '{"text":null}'):
            self.assertIsNone(parse_completion(bad))
            self.assertEqual(total_reward(reward_components(bad, 'Hi', 'Hi')), 0)

    def test_rewrite_gate_and_similarity(self):
        self.assertEqual(total_reward(reward_components('{"text":"Yes I can help you"}',
                         'can you help me', 'Can you help me?')), 0)
        exact = total_reward(reward_components('{"text":"Please send the report."}',
                            'Please send the report.', 'Please send the report.'))
        copy = total_reward(reward_components('{"text":"um please send the report"}',
                           'um please send the report', 'Please send the report.'))
        self.assertGreater(exact, copy)

    def test_fact_retraction_length(self):
        base = reward_components('{"text":"Ask Mara about 42 invoices tomorrow."}',
                                 'Ask Mara about 42 invoices tomorrow.',
                                 'Ask Mara about 42 invoices tomorrow.')
        lost = reward_components('{"text":"Ask about invoices tomorrow."}',
                                 'Ask Mara about 42 invoices tomorrow.',
                                 'Ask Mara about 42 invoices tomorrow.')
        self.assertLess(lost['facts'], base['facts'])
        kept = reward_components('{"text":"No, meet Tuesday."}',
                                 'Meet Monday, no, Tuesday.', 'Meet Tuesday.')
        clean = reward_components('{"text":"Meet Tuesday."}',
                                  'Meet Monday, no, Tuesday.', 'Meet Tuesday.')
        self.assertLess(kept['retracted'], clean['retracted'])
        long = reward_components('{"text":"Please send the report please send the report please send the report."}',
                                 'Please send the report please send the report please send the report.',
                                 'Please send the report.')
        self.assertLess(long['length'], 0)

    def test_normalizer(self):
        self.assertEqual(normalized_words('Nine, OKAY! Don’t'), ['9', 'ok', "don't"])

    def test_sealed_paths(self):
        for term in ('heldout', 'voicelab', 'ab-', 'long64-b', 'longb'):
            with self.assertRaises(ValueError): safe_path('/tmp/' + term + '.jsonl')


if __name__ == '__main__':
    unittest.main()
