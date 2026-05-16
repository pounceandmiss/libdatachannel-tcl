package require tcltest 2.5
namespace import ::tcltest::*

package require rtc
::rtc::set-log-level error

test pc-lifecycle-1.0 {pc::new returns positive id; delete returns 0} -body {
    set pc [::rtc::pc::new]
    set positive [expr {$pc > 0}]
    set rc [::rtc::pc::delete $pc]
    list $positive $rc
} -result {1 0}

test pc-callback-lifecycle-1.0 {register every PC callback, delete, register again on a fresh id - must not crash} -body {
    set pc [::rtc::pc::new]
    ::rtc::pc::on-state-change            $pc dummy
    ::rtc::pc::on-ice-state-change        $pc dummy
    ::rtc::pc::on-gathering-state-change  $pc dummy
    ::rtc::pc::on-signaling-state-change  $pc dummy
    ::rtc::pc::on-local-description       $pc dummy
    ::rtc::pc::on-local-candidate         $pc dummy
    ::rtc::pc::on-data-channel            $pc dummy
    ::rtc::pc::on-track                   $pc dummy
    ::rtc::pc::delete $pc

    set pc [::rtc::pc::new]
    ::rtc::pc::on-state-change $pc dummy
    ::rtc::pc::delete $pc
    set ok 1
} -result 1

test error-return-1.0 {libdatachannel negative return becomes a Tcl error with RTC errorcode} -body {
    catch {::rtc::pc::delete 999999} _ opts
    dict get $opts -errorcode
} -result {RTC invalid}

# Capture failure count before cleanupTests - it resets the counter.
set _failed $::tcltest::numTests(Failed)
cleanupTests
if {$_failed > 0} { exit 1 }
