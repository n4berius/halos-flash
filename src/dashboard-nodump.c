/* Preloaded into halogen-dashboard by dashboard-run (LD_PRELOAD), so the process is not dumpable.
 *
 * The dashboard holds Halogen's API key in its environment (HALOGEN_API_KEY). A dumpable process
 * that crashes is handed to systemd-coredump, which writes its environment, key included, to the
 * journal; LimitCORE=0 doesn't stop that. A process that is not dumpable is never handed to a
 * core handler at all, and its /proc files (environ, mem, maps) belong to root.
 *
 * It has to run inside the dashboard: execve() makes a process dumpable again, so a wrapper that
 * did this before exec would be undone. If the call fails the process exits (70) instead of
 * running dumpable; halos-dashboard.service then restarts it and the selftest reports it.
 */
#include <sys/prctl.h>
#include <unistd.h>

__attribute__((constructor)) static void halos_dashboard_nodump(void)
{
	if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0)
		_exit(70);
}
