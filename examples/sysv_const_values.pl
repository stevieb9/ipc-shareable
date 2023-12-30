use warnings;
use strict;

use IPC::SysV qw(:all);

{
    no strict 'refs';

    for my $const (constants()) {
        printf("%s: %d\n", $const, $const->());
    }

}

sub constants {
    return qw(
        IPC_CREAT
        IPC_EXCL
        IPC_NOWAIT
        IPC_PRIVATE
        IPC_RMID
        IPC_SET
        IPC_STAT
        GETVAL
        SETVAL
        GETPID
        GETNCNT
        GETZCNT
        GETALL
        SETALL
        SEM_A
        SEM_R
        SEM_UNDO
        SHM_RDONLY
        SHM_RND
        SHMLBA
        S_IRUSR
        S_IWUSR
        S_IRWXU
        S_IRGRP
        S_IWGRP
        S_IRWXG
        S_IROTH
        S_IWOTH
        S_IRWXO
    );
}