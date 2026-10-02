#!/usr/bin/env bash
# Bounded primary-side receiver, invoked with bash:
#   fm-remote-receive.sh <seconds> <stdout-cap> <stderr-cap> <status-file> <command> [args...]
# fm-timeout-lib.sh owns the deadline; byte caps apply independently before
# bytes reach the caller's output files. Callers publish output only for exit:0.
# A successful receiver writes exit:<command-status>, over:stdout, over:stderr,
# or timeout to status-file. Receiver failures exit 2 and must not be confused
# with a remote-controlled exit status recorded in that file.
# The command must implement fm-on.sh's FM_ON_LOCAL_STATUS launch handshake:
# mark remote immediately before exec, restoring local if setup or exec fails.
# This locally owned marker keeps missing helpers and failed local launches
# distinguishable from remote refusals without reserving a remote exit code.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh" || exit 2
seconds=$1
limit=$2
error_limit=$3
status_file=$4
shift 4
launch_file="$status_file.launch"
printf 'local\n' > "$launch_file" || exit 2
trap 'rm -f -- "$launch_file"' EXIT
rc=0
receiver=$(cat <<'PERL'
use strict;
use warnings;
use IPC::Open3;
use IO::Select;
use Symbol qw(gensym);
my ($limit, $error_limit, $status_file, $launch_file, @command) = @ARGV;
sub finish {
  open(my $status, ">", $status_file) or die "status open: $!";
  print {$status} "$_[0]\n" or die "status write: $!";
  close($status) or die "status close: $!";
}
my $pid;
END { local $?; if ($pid) { kill "KILL", $pid; waitpid($pid, 0); } }
eval {
finish("reading");
$ENV{FM_ON_LOCAL_STATUS} = $launch_file;
my ($in, $out, $err) = (gensym, gensym, gensym);
$pid = open3($in, $out, $err, @command);
close($in) or die "stdin close: $!";
my $select = IO::Select->new($out, $err);
my %left = (fileno($out) => $limit, fileno($err) => $error_limit);
while ($select->count) {
  for my $handle ($select->can_read) {
    my $fd = fileno($handle);
    my $want = $left{$fd} + 1;
    $want = 65536 if $want > 65536;
    my $read = sysread($handle, my $chunk, $want);
    if (!defined $read) { next if $!{EINTR}; die "read: $!"; }
    if (!$read) { $select->remove($handle); next; }
    $left{$fd} -= $read;
    if ($left{$fd} < 0) {
      close(STDOUT) or die "stdout close: $!";
      close(STDERR) or die "stderr close: $!";
      finish($fd == fileno($out) ? "over:stdout" : "over:stderr");
      exit 0;
    }
    my $destination = $fd == fileno($out) ? *STDOUT : *STDERR;
    print {$destination} $chunk or die "write: $!";
  }
}
close(STDOUT) or die "stdout close: $!";
close(STDERR) or die "stderr close: $!";
waitpid($pid, 0) == $pid or die "wait: $!";
my $status = $?;
$pid = 0;
open(my $launch, "<", $launch_file) or die "launch open: $!";
my $launched = <$launch>;
defined($launched) && $launched eq "remote\n" or die "local launch failed";
finish("exit:" . (($status & 127) ? 128 + ($status & 127) : $status >> 8));
};
if ($@) { print STDERR $@; exit 2; }
PERL
) || exit 2
fm_run_timed "$seconds" perl -e "$receiver" "$limit" "$error_limit" "$status_file" "$launch_file" "$@" || rc=$?
if [ "$rc" -eq 124 ] && [ "$(cat "$status_file")" = reading ]; then
  printf 'timeout\n' > "$status_file" || exit 2
  exit 0
fi
[ "$rc" -eq 0 ] || exit 2
