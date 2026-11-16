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

import com.intland.codebeamer.controller.ApplicationContextHolder;
import com.intland.codebeamer.manager.ProjectManager;
import com.intland.codebeamer.manager.testmanagement.TestRun;
import com.intland.codebeamer.manager.testmanagement.TestRunnerEngine;
import com.intland.codebeamer.persistence.dto.ProjectDto;
import com.intland.codebeamer.persistence.dto.RoleDto;
import com.intland.codebeamer.persistence.dto.TrackerItemDto;
import com.intland.codebeamer.persistence.dto.UserDto;
import com.intland.codebeamer.persistence.dto.base.NamedDto;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.aspectj.lang.ProceedingJoinPoint;
import org.aspectj.lang.annotation.Around;
import org.aspectj.lang.annotation.Aspect;
import org.aspectj.lang.annotation.Pointcut;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Per-assignee test-runner filter, compile-time woven into
 * {@link TestRunnerEngine#getTestCaseRunsRecursively()}.
 *
 * <p>When a single parent Test Run contains child cases assigned to
 * multiple testers, each tester sees and steps through only the cases
 * assigned to them. "Assigned to them" includes:</p>
 * <ul>
 *   <li><b>Direct user assignment</b> — the case's <em>Assigned to</em>
 *       contains the current user.</li>
 *   <li><b>Role assignment</b> — the case's <em>Assigned to</em> contains
 *       a <em>role</em>, and the current user holds that role in the
 *       case's project (including roles inherited via group membership).</li>
 * </ul>
 *
 * <p>Parent completion gating
 * ({@code TestRun.getNoOfNotEditableUnfinishedChildTestRuns()}) is on a
 * different declaring class and is NOT advised here, so the parent run
 * stays open until ALL testers finish.</p>
 *
 * <h3>Why role resolution is needed (v2.1)</h3>
 * <p>{@code TrackerItemDto.getAssignedTo()} returns a list of
 * {@link NamedDto} that can be {@link UserDto} <i>or</i> {@link RoleDto}
 * (or a user group). v2.0 matched only {@code UserDto}, so cases assigned
 * to a <b>role</b> were filtered out for everyone — a tester whose role
 * matched still saw nothing. v2.1 resolves the current user's roles in the
 * case's project via {@link ProjectManager#getProjectMemberRoles} and
 * matches role assignees too.</p>
 *
 * <h3>On / off model (Option B - no runtime switch)</h3>
 * <p>The filter is active whenever these woven classes are deployed under
 * {@code WEB-INF/classes}. There is no JVM property and no config toggle:
 * a global class-shadow makes any switch application-wide anyway, so
 * ON = deployed, OFF = remove the classes (the rollback). See
 * DEPLOYMENT-RUNBOOK.md §5.4.</p>
 *
 * <h3>Failure mode (fail-open)</h3>
 * <p>If any step throws, the original unfiltered list is returned with a
 * WARN log. If the current user's roles cannot be resolved for a project,
 * role-assigned cases in that project are kept visible (fail-open) rather
 * than hidden. The runner stays fully functional; verdicts, audit logging,
 * and locking are unaffected.</p>
 *
 * <h3>Known caveats</h3>
 * <ul>
 *   <li><b>Direct group assignment:</b> a case assigned directly to a user
 *       <em>group</em> (not a role) is not matched by group membership in
 *       v2.1 — only users and roles are matched. Roles inherited <em>via</em>
 *       a group ARE matched (getProjectMemberRoles folds them in). If direct
 *       group-assignment support is needed, extend {@link #isAssignedToUser}.</li>
 *   <li><b>Structural (folder) rows / unassigned rows:</b> kept visible
 *       (return {@code true}) so nested-test-set rendering is not broken.</li>
 *   <li><b>Cursor index:</b> the engine's cursor index is set against the
 *       unfiltered list; if a tester lands pre-positioned beyond the filtered
 *       size, {@code getCurrentTestCaseRun()} may return {@code null}; the
 *       runner UI handles this or the tester resets via {@code #jumpTo}.</li>
 *   <li><b>Parameterised variants:</b> share the parent case's assignment,
 *       so they filter correctly without special handling.</li>
 * </ul>
 *
 * <h3>Future: per-project (per-business-unit) scoping</h3>
 * <p>Deployment is global. If per-business-unit enablement is required
 * (e.g. CT projects but not Ultrasound), add a project-allowlist check at
 * the top of {@link #isAssignedToUser}: only filter when the case's project
 * is on an allowlist read from a {@code custom/} config file; otherwise
 * return {@code true} (show all). Same deployment, no new mechanism.</p>
 *
 * @author PTC Customization - Philips
 * @version 2.1
 * @since 2026-06-23
 */
@Aspect
public class AssignedRunFilterAspect {

    private static final Logger log = LogManager.getLogger(AssignedRunFilterAspect.class);

    static {
        log.info("AssignedRunFilterAspect v2.1 loaded - per-assignee filtering is ACTIVE "
                + "(matches direct-user AND role assignments; active whenever these woven classes are deployed).");
    }

    @Pointcut("execution(java.util.List "
            + "com.intland.codebeamer.manager.testmanagement.TestRunnerEngine.getTestCaseRunsRecursively())")
    public void testCaseRunsRecursively() {}

    /**
     * Around advice: filter the engine's backbone list to runs assigned to
     * the current user (directly or via a role they hold). Fails open on any
     * exception.
     */
    @Around("testCaseRunsRecursively()")
    public Object filterRecursiveRuns(ProceedingJoinPoint pjp) throws Throwable {
        Object result = pjp.proceed();
        try {
            if (!(result instanceof List)) {
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

            // Per-call cache of the user's role ids, keyed by project id, so we
            // resolve role membership at most once per project per invocation.
            final Map<Integer, Set<Integer>> roleIdsByProject = new HashMap<>();

            List<TestRun> mine = new ArrayList<>(all.size());
            for (TestRun run : all) {
                if (isAssignedToUser(run, currentUser, roleIdsByProject)) {
                    mine.add(run);
                }
            }

            if (log.isDebugEnabled()) {
                log.debug("AssignedRunFilterAspect: user [{}] filtered {} -> {} runs",
                        currentUser.getId(), all.size(), mine.size());
            }
            if (mine.isEmpty() && !all.isEmpty()) {
                log.warn("AssignedRunFilterAspect: filter produced empty set from {} runs for user [{}] - tester sees 'no work' UI",
                        all.size(), currentUser.getId());
            }
            return mine;
        } catch (Throwable t) {
            log.warn("AssignedRunFilterAspect: filter logic threw [{}] - returning unfiltered list (fail-open)",
                    t.toString(), t);
            return result;
        }
    }

    /**
     * True when the run should be visible to the user: assigned directly to
     * the user, assigned to a role the user holds in the run's project, OR a
     * structural/unassigned row (kept visible).
     */
    private boolean isAssignedToUser(TestRun run, UserDto user, Map<Integer, Set<Integer>> roleIdsByProject) {
        if (run == null) return false;
        TrackerItemDto item = run.getDelegate();
        if (item == null) return true; // structural / no delegate -> keep visible

        List<? extends NamedDto> assignedTo = item.getAssignedTo();
        if (assignedTo == null || assignedTo.isEmpty()) return true; // unassigned -> keep visible

        // (1) direct user assignment
        boolean hasRoleAssignee = false;
        for (NamedDto a : assignedTo) {
            if (a == null) continue;
            if (a instanceof UserDto) {
                if (user.equals(a)) return true;
            } else if (a instanceof RoleDto) {
                hasRoleAssignee = true;
            }
        }

        // (2) role assignment: does the user hold any assigned role in this project?
        if (hasRoleAssignee) {
            Set<Integer> userRoleIds = userRoleIdsInProject(item, user, roleIdsByProject);
            if (userRoleIds == null) {
                // role resolution failed -> fail-open: keep the (role-assigned) run visible
                return true;
            }
            for (NamedDto a : assignedTo) {
                if (a instanceof RoleDto) {
                    Integer roleId = ((RoleDto) a).getId();
                    if (roleId != null && userRoleIds.contains(roleId)) return true;
                }
            }
        }
        return false;
    }

    /**
     * Resolve the set of role ids the user holds in the given item's project
     * (including roles inherited via group membership). Cached per project id
     * for the duration of one advice invocation. Returns {@code null} if the
     * project or the ProjectManager bean cannot be resolved (caller fails open).
     */
    private Set<Integer> userRoleIdsInProject(TrackerItemDto item, UserDto user, Map<Integer, Set<Integer>> cache) {
        ProjectDto project = item.getProject();
        if (project == null || project.getId() == null) return null;
        final Integer pid = project.getId();

        Set<Integer> cached = cache.get(pid);
        if (cached != null) return cached;

        Set<Integer> ids = new HashSet<>();
        try {
            ProjectManager projectManager = ApplicationContextHolder.getInstance()
                    .getApplicationContext().getBean(ProjectManager.class);
            // (project, member, includeGroupRoles=true) -> roles the user holds, folding in group-derived roles
            List<RoleDto> roles = projectManager.getProjectMemberRoles(project, user, true);
            if (roles != null) {
                for (RoleDto r : roles) {
                    if (r != null && r.getId() != null) ids.add(r.getId());
                }
            }
        } catch (Throwable t) {
            log.warn("AssignedRunFilterAspect: could not resolve roles for user [{}] in project [{}] - {} (failing open for role-assigned runs)",
                    user.getId(), pid, t.toString());
            return null; // signal "unknown" -> caller keeps role-assigned runs visible
        }
        cache.put(pid, ids);
        return ids;
    }
}
