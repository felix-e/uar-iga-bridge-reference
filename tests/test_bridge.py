"""Offline checks of illustrative policy, not historical campaign evidence."""
import copy
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from bridge import (Blocked, compare_populations, notification_preview,
                    route_candidates, run_example)

ROOT = Path(__file__).resolve().parents[1]


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads((ROOT / 'examples/input.json').read_text())

    def route(self):
        return route_candidates(self.data['catalogue'], self.data['population'])

    def test_successful_synthetic_example(self):
        expected = json.loads((ROOT / 'examples/expected.json').read_text())
        self.assertEqual(run_example(self.data), expected)
        candidates = self.route()
        self.assertEqual([row['reviewer_id'] for row in candidates],
                         ['manager-001', 'delegate-001'])
        self.assertTrue(expected['comparison']['matches'])
        self.assertEqual(len(expected['notification_preview']), 1)

    def test_catalogue_blockers_precede_candidate_routing(self):
        for mutation in ('missing', 'duplicate', 'conflicting', 'dynamic',
                         'missing_type', 'classification'):
            with self.subTest(mutation=mutation):
                data = copy.deepcopy(self.data)
                catalogue = data['catalogue']
                if mutation == 'missing':
                    catalogue.pop()
                elif mutation in ('duplicate', 'conflicting'):
                    extra = copy.deepcopy(catalogue[0])
                    if mutation == 'conflicting':
                        extra['classification'] = 'Privileged'
                    catalogue.append(extra)
                elif mutation == 'dynamic':
                    catalogue[1]['mapping_type'] = 'dynamic'
                elif mutation == 'missing_type':
                    del catalogue[1]['mapping_type']
                else:
                    del catalogue[1]['classification']
                # No population processing (and thus routing) before catalogue gate.
                with patch('bridge._population_index', side_effect=AssertionError):
                    with self.assertRaises(Blocked):
                        route_candidates(catalogue, data['population'])

    def test_unused_dynamic_catalogue_mapping_also_blocks(self):
        self.data['catalogue'].append(dict(application_id='app-demo',
            entitlement_id='entitlement-003', mapping_type='dynamic'))
        with self.assertRaises(Blocked):
            self.route()

    def test_missing_or_inactive_manager_uses_named_owner(self):
        for manager in (None, '', 'manager-001'):
            self.data['population'][0].update(manager_id=manager, manager_active=False)
            self.assertEqual(self.route()[0]['reviewer_id'], 'owner-001')
        self.data['population'][0].update(manager_id=None, manager_active=True)
        self.assertEqual(self.route()[0]['route'], 'owner')

    def test_missing_owner_and_delegate_blocks(self):
        del self.data['catalogue'][1]['delegate_id']
        with self.assertRaises(Blocked):
            self.route()

    def test_self_review_blocks_without_inventing_fallback(self):
        for route in ('manager', 'owner', 'delegate'):
            with self.subTest(route=route):
                data = copy.deepcopy(self.data)
                index = 1 if route == 'delegate' else 0
                if route == 'owner':
                    data['population'][0]['manager_active'] = False
                reviewer = {'manager': 'manager-001', 'owner': 'owner-001',
                            'delegate': 'delegate-001'}[route]
                data['population'][index]['subject_id'] = reviewer
                with self.assertRaises(Blocked):
                    route_candidates(data['catalogue'], data['population'])

    def test_missing_subject_blocks(self):
        del self.data['population'][0]['subject_id']
        with self.assertRaises(Blocked):
            self.route()

    def test_same_total_different_membership_is_not_a_match(self):
        proposed = self.route()
        proposed[0]['account_id'] = 'account-003'
        result = compare_populations(self.data['current'], proposed)
        self.assertEqual(result['current_count'], result['proposed_count'])
        self.assertFalse(result['matches'])
        self.assertEqual(result['removed'][0]['account_id'], 'account-001')
        self.assertEqual(result['added'][0]['account_id'], 'account-003')

    def test_entitlement_membership_change_is_detected(self):
        proposed = self.route()
        proposed[0]['entitlement_id'] = 'entitlement-003'
        result = compare_populations(self.data['current'], proposed)
        self.assertFalse(result['matches'])
        self.assertEqual(len(result['added']), 1)
        self.assertEqual(len(result['removed']), 1)

    def test_reviewer_drift_is_detected(self):
        proposed = self.route()
        proposed[0]['reviewer_id'] = 'owner-001'
        result = compare_populations(self.data['current'], proposed)
        self.assertFalse(result['matches'])
        self.assertEqual(result['added'], [])
        self.assertEqual(result['removed'], [])
        self.assertEqual(result['reviewer_drift'][0]['current_reviewer_id'], 'manager-001')
        self.assertEqual(result['reviewer_drift'][0]['proposed_reviewer_id'], 'owner-001')

    def test_duplicate_or_incomplete_population_blocks(self):
        for field in (None, 'account_id', 'tag'):
            rows = copy.deepcopy(self.data['current'])
            if field:
                del rows[0][field]
            else:
                rows.append(copy.deepcopy(rows[0]))
            with self.assertRaises(Blocked):
                compare_populations(rows, self.route())

    def test_preview_filters_action_and_each_scope_dimension(self):
        matching = copy.deepcopy(self.data['decisions'][1])
        decisions = [matching]
        for field in ('action', 'tag', 'cycle', 'application_id'):
            other = {**matching, field: 'other-demo'}
            decisions.append(other)
        snapshot = copy.deepcopy(decisions)
        preview = notification_preview(decisions, **self.data['preview_scope'])
        self.assertEqual(len(preview), 1)
        self.assertEqual(preview[0]['action'], 'remove')
        self.assertEqual(preview[0]['account_id'], 'account-002')
        self.assertNotIn('subject_id', preview[0])
        self.assertEqual(decisions, snapshot)
        scope = {**self.data['preview_scope'], 'tag': 'tag-other'}
        self.assertEqual(notification_preview(decisions, **scope), [])

    def test_preview_requires_explicit_scope_and_known_action(self):
        for field in self.data['preview_scope']:
            scope = {**self.data['preview_scope'], field: ''}
            with self.assertRaises(Blocked):
                notification_preview(self.data['decisions'], **scope)

    def test_preview_blocks_self_review(self):
        self.data['decisions'][1]['reviewer_id'] = 'subject-002'
        with self.assertRaises(Blocked):
            notification_preview(self.data['decisions'], **self.data['preview_scope'])


if __name__ == '__main__':
    unittest.main()
