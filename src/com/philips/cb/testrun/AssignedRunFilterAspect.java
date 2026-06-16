/*
 * Copyright (c) 2026 PTC Inc. - Customization for Philips.
 * All rights reserved.
 *
 * Customization: Per-Assignee Test Runner Filter (Codebeamer 3.0.0.5)
 * Mechanism: Compile-Time Weaving (CTW) via AspectJ, deployed as
 *            class-shadow in tomcat/webapps/cb/WEB-INF/classes/.
 * See DEPLOYMENT-RUNBOOK.md (same folder) for build + deploy + rollback.
 */
package com.philips.cb.testrun;

import com.intland.codebeamer.manager.testmanagement.TestRun;
import com.intland.codebeamer.manager.testmanagement.TestRunnerEngine;
import com.intland.codebeamer.persistence.dto.TrackerItemDto;
import com.intland.codebeamer.persistence.dto.UserDto;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.aspectj.lang.ProceedingJoinPoint;
import org.aspectj.lang.annotation.Around;
import org.aspectj.lang.annotation.Aspect;
import org.aspectj.lang.annotation.Pointcut;

import java.util.List;
import java.util.Objects;
import java.util.stream.Collectors;

/**
 * Per-assignee test-runner filter, compile-time woven into
 * {@link TestRunnerEngine#getTestCaseRunsRecursively()}.
 *
 * <p>When a single parent Test Run contains child cases assigned to
 * multiple testers, each tester sees and steps through only their own
 * assigned cases. Parent completion gating
 * ({@code TestRun.getNoOfNotEditableUnfinishedChildTestRuns()}) is on a
 * different declaring class and is NOT advised here, so the parent run
 * stays open until ALL testers finish. Side panels that read child
 * lists via the wiki plugin call {@code TestRun.getTestCaseRunsRecursively()}
 * (different class) and remain unfiltered by design.</p>
 *
 * <h3>Master switch</h3>
 * <p>Controlled by the system property
 * {@value #SYSTEM_PROPERTY_KEY}. <b>Default is OFF</b> - operators must
 * explicitly enable by adding {@code -D<key>=true} to the procrun
 * service JVM options. This makes the binary class drop safe under
 * rollback windows: shipping the class files alone does not change
 * runtime behaviour.</p>
 *
 * <h3>Failure mode (fail-open)</h3>
 * <p>If any step of the filter throws, the original unfiltered list
 * is returned with a WARN log. The runner remains fully functional;
 * verdicts, audit logging, and locking are unaffected.</p>
 *
 * <h3>Known caveats</h3>
 * <ul>
 *   <li><b>Structural (folder) rows:</b> rows with no {@code assignedTo}
 *       are intentionally kept visible (return {@code true}). Dropping
 *       them would break nested-test-set tree rendering.</li>
 *   <li><b>Cursor index:</b> the engine's internal cursor index is set
 *       against the unfiltered list during construction. If a tester
 *       lands on a runner pre-positioned beyond the filtered list size,
 *       {@code getCurrentTestCaseRun()} may return {@code null}; the
 *       runner UI handles this gracefully or the tester resets via
 *       the {@code #jumpTo} input.</li>
 *   <li><b>Parameterised variants:</b> share the parent case's
 *       {@code assignedTo}, so the filter behaves correctly for them
 *       without special handling.</li>
 * </ul>
 *
 * <h3>Build / deploy</h3>
 * <p>Compile-time-woven via ajc 1.9.22 against the deployed
 * {@code cb-3.0.0.5.jar}; runtime resolves against the shipped
 * {@code aspectjweaver-1.9.7.jar} on the webapp classpath. The
 * tools/runtime version split is intentional (see ADR-0004). Deployed
 * via {@code WEB-INF/classes} shadowing; the {@code .class} files live
 * at:
 * <pre>
 * com/intland/codebeamer/manager/testmanagement/TestRunnerEngine.class
 * com/intland/codebeamer/manager/testmanagement/TestRunnerEngine$AjcClosure1.class
 * com/philips/cb/testrun/AssignedRunFilterAspect.class  (this aspect)
 * </pre>
 * See {@code DEPLOYMENT-RUNBOOK.md} for the apply / rollback procedure.</p>
 *
 * @author PTC Customization - Philips
 * @version 1.0
 * @since 2026-06-16
 */
@Aspect
public class AssignedRunFilterAspect {

    private static final Logger log = LogManager.getLogger(AssignedRunFilterAspect.class);

    /** System property controlling whether the filter is active. */
    static final String SYSTEM_PROPERTY_KEY = "philips.testrun.assigneeFilter";

    /**
     * Default: OFF. Operators must explicitly opt in. This is the
     * deliberate inversion of the spike default; it makes a fresh class
     * drop safe under rollback windows.
     */
    private static final boolean SYSTEM_PROPERTY_DEFAULT = false;

    static {
        String raw = System.getProperty(SYSTEM_PROPERTY_KEY);
        log.info("AssignedRunFilterAspect loaded. Master switch {}={} (resolved enabled={})",
                SYSTEM_PROPERTY_KEY,
                raw == null ? "<unset, defaulting to OFF>" : raw,
                isEnabled());
    }

    private static boolean isEnabled() {
        String raw = System.getProperty(SYSTEM_PROPERTY_KEY);
        if (raw == null) return SYSTEM_PROPERTY_DEFAULT;
        return Boolean.parseBoolean(raw);
    }

    @Pointcut("execution(java.util.List "
            + "com.intland.codebeamer.manager.testmanagement.TestRunnerEngine.getTestCaseRunsRecursively())")
    public void testCaseRunsRecursively() {}

    /**
     * Around advice: filter the engine's backbone list to runs assigned
     * to the current user. Fails open on any exception.
     */
    @Around("testCaseRunsRecursively()")
    public Object filterRecursiveRuns(ProceedingJoinPoint pjp) throws Throwable {
        Object result = pjp.proceed();
        try {
            if (!isEnabled() || !(result instanceof List)) {
                return result;
            }
            @SuppressWarnings("unchecked")
            List<TestRun> all = (List<TestRun>) result;

            UserDto currentUser = null;
            Object target = pjp.getThis();
            if (target instanceof TestRunnerEngine) {
                currentUser = ((TestRunnerEngine) target).getUser();
            }
            if (currentUser == null) {
                log.warn("AssignedRunFilterAspect: currentUser is null on engine [{}] - returning unfiltered list (fail-open)",
                        target);
                return all;
            }

            final UserDto me = currentUser;
            List<TestRun> mine = all.stream()
                    .filter(run -> assignedToContains(run, me))
                    .collect(Collectors.toList());

            if (log.isDebugEnabled()) {
                log.debug("AssignedRunFilterAspect: user [{}] filtered {} -> {} runs",
                        me.getId(), all.size(), mine.size());
            }
            if (mine.isEmpty() && !all.isEmpty()) {
                log.warn("AssignedRunFilterAspect: filter produced empty set from {} runs for user [{}] - tester sees 'no work' UI",
                        all.size(), me.getId());
            }
            return mine;
        } catch (Throwable t) {
            log.warn("AssignedRunFilterAspect: filter logic threw [{}] - returning unfiltered list (fail-open)",
                    t.toString(), t);
            return result;
        }
    }

    /**
     * True when the given run is assigned to the user, OR when the
     * run is a structural row with no {@code assignedTo} (folder /
     * grouping row that carries no work and must remain visible for
     * nested-test-set rendering).
     *
     * <p>Null elements inside the {@code assignedTo} list are skipped
     * defensively to avoid an NPE propagating out of the around-advice.</p>
     */
    private static boolean assignedToContains(TestRun run, UserDto user) {
        if (run == null) return false;
        TrackerItemDto item = run.getDelegate();
        if (item == null) return true;
        List<?> assignedTo = item.getAssignedTo();
        if (assignedTo == null || assignedTo.isEmpty()) return true;
        return assignedTo.stream()
                .filter(Objects::nonNull)
                .anyMatch(user::equals);
    }
}
