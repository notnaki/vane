#!/usr/bin/env python3
import datetime
import hashlib
import importlib.util
import sys
from pathlib import Path
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("icloud", Path(__file__).with_name("icloud-entitlements.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class ProvisioningTests(unittest.TestCase):
    def setUp(self):
        self.app = "ABCDE12345.io.github.notnaki.vane"
        self.cert = b"fixture certificate bytes"
        self.digest = hashlib.sha1(self.cert).hexdigest().upper()
        self.identities = f'1) {self.digest} "Fixture Identity"'
        self.profile = {
            "ExpirationDate": datetime.datetime.now() + datetime.timedelta(days=2),
            "Platform": ["OSX"], "TeamIdentifier": ["ABCDE12345"],
            "DeveloperCertificates": [self.cert],
            "Entitlements": {
                "com.apple.application-identifier": self.app,
                "com.apple.developer.team-identifier": "ABCDE12345",
                "com.apple.developer.icloud-container-identifiers": ["iCloud.fixture.assigned"],
                "com.apple.developer.icloud-services": ["CloudKit"],
                "com.apple.developer.icloud-container-environment": "Development",
                "com.apple.developer.aps-environment": "development",
                "keychain-access-groups": [self.app], "get-task-allow": True,
            },
        }
    def generate(self, **kwargs):
        return module.generate(self.profile, {"com.apple.security.app-sandbox": True}, "iCloud.fixture.assigned", "Fixture Identity", self.identities, **kwargs)
    def testCopiesOnlyRestrictedGrantsAndPreservesSandbox(self):
        result = self.generate()
        self.assertTrue(result["com.apple.security.app-sandbox"])
        self.assertEqual(result["keychain-access-groups"], [self.app])
        self.assertNotIn("get-task-allow", result)
    def testRejectsExpiredProfile(self):
        self.profile["ExpirationDate"] = datetime.datetime(2000, 1, 1)
        with self.assertRaisesRegex(ValueError, "expired"): self.generate()
    def testRejectsWildcardApplication(self):
        self.profile["Entitlements"]["com.apple.application-identifier"] = "ABCDE12345.*"
        with self.assertRaisesRegex(ValueError, "exact application"): self.generate()
    def testRejectsUnassignedContainer(self):
        self.profile["Entitlements"]["com.apple.developer.icloud-container-identifiers"] = ["iCloud.other"]
        with self.assertRaisesRegex(ValueError, "not explicitly authorized"): self.generate()
    def testRejectsDifferentSigningCertificate(self):
        self.profile["DeveloperCertificates"] = [b"other"]
        with self.assertRaisesRegex(ValueError, "certificate is not authorized"): self.generate()
    def testNarrowsAppleProfileWildcardGrantsToVaneOnly(self):
        grants = self.profile["Entitlements"]
        grants["com.apple.developer.icloud-services"] = "*"
        grants["com.apple.developer.icloud-container-environment"] = ["Production", "Development"]
        grants["keychain-access-groups"] = ["ABCDE12345.*"]
        result = self.generate()
        self.assertEqual(result["com.apple.developer.icloud-services"], ["CloudKit"])
        self.assertEqual(result["com.apple.developer.icloud-container-environment"], "Development")
        self.assertEqual(result["keychain-access-groups"], [self.app])
    def testExplicitEnvironmentMustBeAuthorized(self):
        grants = self.profile["Entitlements"]
        grants["com.apple.developer.icloud-container-environment"] = ["Production", "Development"]
        self.assertEqual(self.generate(environment="Production")["com.apple.developer.icloud-container-environment"], "Production")
        grants["com.apple.developer.icloud-container-environment"] = ["Development"]
        with self.assertRaisesRegex(ValueError, "CloudKit environment"): self.generate(environment="Production")
        with self.assertRaisesRegex(ValueError, "CloudKit environment"): self.generate(environment="anything")
    def testRejectsForeignAndUnscopedWildcardKeychainGroups(self):
        for group in ["OTHER12345.*", "*", "ABCDE12345.io.github.notnaki.other"]:
            self.profile["Entitlements"]["keychain-access-groups"] = [group]
            with self.assertRaisesRegex(ValueError, "Keychain group"): self.generate()
    def testTeamWildcardDoesNotAuthorizeAnotherApplication(self):
        self.profile["Entitlements"]["keychain-access-groups"] = ["ABCDE12345.*"]
        self.profile["Entitlements"]["com.apple.application-identifier"] = "ABCDE12345.io.github.notnaki.other"
        with self.assertRaisesRegex(ValueError, "exact application"): self.generate()

if __name__ == "__main__": unittest.main()
