package File::Patch::Undoable;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::ger;

use Capture::Tiny qw(capture);
use File::Temp qw(tempfile);
use IPC::System::Options 'system', -log=>1;
use Proc::ChildError qw(explain_child_error);

our %SPEC;

sub _check_patch_has_dry_run_option {
    # some versions of the 'patch' program, like that on freebsd, does not
    # support the needed --dry-run option. we currently can't run on those
    # systems.

    # this currently doesn't work on openbsd, since openbsd's patch does not
    # exit non-zero if fed unknown options.
    #my (undef, undef, $exit) = capture { system "patch --dry-run -v" };
    #return $exit == 0;

    # cache result
    state $res = do {
        # hm, what about windows?
        #my $man = qx(man patch);
        #$man =~ /--dry-run/;

        my $help = qx(patch --help);
        $help =~ /--dry-run/;
    };

    $res;
}

$SPEC{patch} = {
    v           => 1.1,
    summary     => 'Patch a file, with undo support',
    description => <<'_',

On do, will patch file with the supplied patch. On undo, will apply the reverse
of the patch.

Note: Symlink is currently not permitted (except for the patch file). Patching
is currently done with the <prog:patch> program.

Unfixable state: file does not exist or not a regular file (directory and
symlink included), patch file does not exist or not a regular file (but symlink
allowed).

Fixed state: file exists, patch file exists, and patch has been applied.

Fixable state: file exists, patch file exists, and patch has not been applied.

_
    args        => {
        # naming the args 'path' and 'patch' can be rather error prone
        file => {
            summary => 'Path to file to be patched',
            schema => 'str*',
            req    => 1,
            pos    => 0,
        },
        patch => {
            summary => 'Path to patch file',
            description => <<'_',

Patch can be in unified or context format, it will be autodetected.

_
            schema => 'str*',
            req    => 1,
            pos    => 1,
        },
        reverse => {
            summary => 'Whether to apply reverse of patch',
            schema => [bool => {default=>0}],
            cmdline_aliases => {R=>{}},
        },
    },
    features => {
        tx => {v=>2},
        idempotent => 1,
    },
    deps => {
        prog => 'patch',
    },
};
sub patch {
    my %args = @_;

    # TMP, schema
    my $tx_action  = $args{-tx_action} // '';
    my $dry_run    = $args{-dry_run};
    my $file       = $args{file};
    defined($file) or return [400, "Please specify file"];
    my $patch      = $args{patch};
    defined($patch) or return [400, "Please specify patch"];
    my $rev        = !!$args{reverse};

    return [412, "The patch program does not support --dry-run option"]
        unless _check_patch_has_dry_run_option();

    my $is_sym  = (-l $file);
    my @st      = stat($file);
    my $exists  = $is_sym || (-e _);
    my $is_file = (-f _);
    my $patch_exists  = (-e $patch);
    my $patch_is_file = (-f _);

    my @cmd;

    if ($tx_action eq 'check_state') {
        return [412, "File $file does not exist"] unless $exists;
        return [412, "File $file is not a regular file"] if $is_sym||!$is_file;
        return [412, "Patch $patch does not exist"] unless $patch_exists;
        return [412,"Patch $patch is not a regular file"] unless $patch_is_file;

        # check whether patch has been applied by testing the reverse patch
        @cmd = ("patch", "--dry-run", "-sf", "-r","-", ("-R")x!$rev,
                $file, "-i",$patch);
        system @cmd;
        if (!$?) {
            return [304, "Patch $patch already applied to $file"];
        } elsif (($? >> 8) == 1) {
            log_info("(DRY) Patching file $file with $patch ...") if $dry_run;
            return [200, "File $file needs to be patched with $patch", undef,
                    {undo_actions=>[
                        [patch=>{file=>$file, patch=>$patch, reverse=>!$rev}],
                    ]}];
        } else {
            return [500, "Can't patch: ".explain_child_error()];
        }

    } elsif ($tx_action eq 'fix_state') {
        log_info("Patching file $file with $patch ...");

        # first patch to a temporary output first, because patch can produce
        # half-patched file.
        my ($tmpfh, $tmpname) = tempfile(DIR=>".");

        @cmd = ("patch", "-sf","-r","-", ("-R")x!!$rev,
                $file, "-i",$patch, "-o", $tmpname);
        system @cmd;
        if ($?) {
            unlink $tmpname;
            return [500, "Can't patch: ".explain_child_error()];
        }

        # now rename the temp file to the original file
        unless (rename $tmpname, $file) {
            unlink $tmpname;
            return [500, "Can't rename $tmpname -> $file: $!"];
        }

        return [200, "OK"];
    }
    [400, "Invalid -tx_action"];
}

1;
# ABSTRACT:

=head1 FAQ

=head2 Why use the patch program? Why not use a Perl module like Text::Patch?

The B<patch> program has many nice features that L<Text::Patch> lacks, e.g.
applying reverse patch (needed to check fixed state and to undo), autodetection
of patch type, ignoring whitespace and fuzz factor, etc.


=head1 KNOWN ISSUES



=head1 SEE ALSO

L<Rinci::Transaction>

L<Text::Patch>, L<PatchReader>, L<Text::Patch::Rred>

=cut
