// The update check trusts nothing git prints: "<behind> <ahead>" as two
// small integers, or the answer is "unknown". Only a strict fast-forward
// (nothing of ours missing upstream, something of theirs missing here) is an
// update. Everything else is a bounded status string.
import QtQuick
import QtTest
import "../UpdateCheck.js" as Logic

Item {
  TestCase {
    name: "UpdateCheck"

    function test_counts() {
      compare(Logic.verdict("0\t0\n"), "current")
      compare(Logic.verdict("0\t3\n"), "update")
      compare(Logic.verdict("2\t0\n"), "current", "ahead of origin: nothing to fast-forward to")
      compare(Logic.verdict("1\t4"), "current", "diverged: the updater would refuse")
    }
    function test_anything_else_is_unknown() {
      compare(Logic.verdict(""), "unknown")
      compare(Logic.verdict("0"), "unknown")
      compare(Logic.verdict("0\t3\t9"), "unknown")
      compare(Logic.verdict("-1\t3"), "unknown")
      compare(Logic.verdict("0\t1e9"), "unknown")
      compare(Logic.verdict("0\t" + "9".repeat(12)), "unknown", "absurd counts are not trusted")
      compare(Logic.verdict("fatal: not a git repository"), "unknown")
      compare(Logic.verdict(null), "unknown")
      compare(Logic.verdict({ toString: function() { return "0\t2" } }), "update", "objects are stringified first")
    }
    function test_a_checkout_newer_than_the_installed_helper_is_an_update() {
      var a = "a".repeat(40), b = "b".repeat(40)
      verify(Logic.installedBehind(a, JSON.stringify({ installed: b })))
      verify(!Logic.installedBehind(a, JSON.stringify({ installed: a })), "installed from this commit")
      verify(!Logic.installedBehind(a, JSON.stringify({ installed: "" })), "a copy, not a checkout")
      verify(!Logic.installedBehind(a, JSON.stringify({ no_shortcuts: true })), "nothing recorded")
      verify(!Logic.installedBehind(a, "not json"))
      verify(!Logic.installedBehind(a, ""))
      verify(!Logic.installedBehind("", JSON.stringify({ installed: b })), "no head to compare")
      verify(!Logic.installedBehind("HEAD", JSON.stringify({ installed: b })))
      verify(!Logic.installedBehind(a, JSON.stringify({ installed: "b".repeat(39) })), "not a commit id")
    }
    function test_only_the_plugins_own_repository_counts() {
      verify(Logic.ownCheckout(".git\n"))
      verify(!Logic.ownCheckout("/home/u/.config/.git\n"), "an enclosing dotfiles repository")
      verify(!Logic.ownCheckout("../.git"))
      verify(!Logic.ownCheckout(""))
      verify(!Logic.ownCheckout("fatal: not a git repository"))
    }
    function test_describe_is_short_and_plain() {
      var statuses = ["idle", "unsupported", "checking", "current", "update", "error", "<b>x</b>"]
      for (var i = 0; i < statuses.length; i++) {
        var s = Logic.describe(statuses[i], "12:00")
        verify(s.length > 0 && s.length < 120)
        verify(s.indexOf("<") === -1, "status text carries no markup: " + s)
      }
      compare(Logic.describe("update", ""), "update available")
    }
  }
}
