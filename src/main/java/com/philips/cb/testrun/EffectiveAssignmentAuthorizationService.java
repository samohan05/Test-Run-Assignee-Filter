package com.philips.cb.testrun;

import com.intland.codebeamer.controller.ApplicationContextHolder;
import com.intland.codebeamer.manager.ProjectManager;
import com.intland.codebeamer.manager.UserManager;
import com.intland.codebeamer.manager.testmanagement.TestRun;
import com.intland.codebeamer.persistence.dto.ProjectDto;
import com.intland.codebeamer.persistence.dto.RoleDto;
import com.intland.codebeamer.persistence.dto.TrackerItemDto;
import com.intland.codebeamer.persistence.dto.UserDto;
import com.intland.codebeamer.persistence.dto.base.NamedDto;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.springframework.context.ApplicationContext;

/**
 * Authorizes Test Runs assigned directly to users or to project roles.
 *
 * <p>Role membership includes direct role membership and membership inherited
 * through a project group, as resolved by Codebeamer's role-user lookup.</p>
 *
 * <p>Direct assignment to a user group is intentionally not supported because
 * the approved customer usage assigns Test Runs only to users and roles.</p>
 */
public final class EffectiveAssignmentAuthorizationService {

    private static final Logger LOGGER =
            LogManager.getLogger(EffectiveAssignmentAuthorizationService.class);

    private final ProjectManager projectManager;
    private final UserManager userManager;
    private final boolean unassignedRunsAuthorized;

    public EffectiveAssignmentAuthorizationService() {
        this(resolveProjectManager(), resolveUserManager(), true);
    }

    EffectiveAssignmentAuthorizationService(
            ProjectManager projectManager,
            UserManager userManager,
            boolean unassignedRunsAuthorized) {
        this.projectManager = Objects.requireNonNull(projectManager);
        this.userManager = Objects.requireNonNull(userManager);
        this.unassignedRunsAuthorized = unassignedRunsAuthorized;
    }

    public boolean isAuthorized(
            TestRun run,
            UserDto currentUser,
            AssignmentAuthorizationContext context) {

        if (run == null || currentUser == null || currentUser.getId() == null
                || context == null) {
            return false;
        }

        TrackerItemDto item = run.getDelegate();
        if (item == null) {
            return false;
        }

        List<? extends NamedDto> assignments = item.getAssignedTo();
        if (assignments == null || assignments.isEmpty()) {
            return unassignedRunsAuthorized;
        }

        for (NamedDto assignment : assignments) {
            if (assignment == null || assignment.getId() == null) {
                continue;
            }

            if (assignment instanceof UserDto
                    && assignment.getId().equals(currentUser.getId())) {
                return true;
            }

            if (assignment instanceof RoleDto
                    && isEffectiveMemberOfRole(
                            item,
                            currentUser,
                            (RoleDto) assignment,
                            context)) {
                return true;
            }
        }
        return false;
    }

    private boolean isEffectiveMemberOfRole(
            TrackerItemDto item,
            UserDto currentUser,
            RoleDto assignedRole,
            AssignmentAuthorizationContext context) {

        ProjectDto project = item.getProject();
        if (project == null || project.getId() == null
                || assignedRole.getId() == null
                || assignedRole.getName() == null) {
            return false;
        }

        if (effectiveRoleIds(project, currentUser, context)
                .contains(assignedRole.getId())) {
            return true;
        }

        RoleMembershipKey key = new RoleMembershipKey(
                currentUser.getId(),
                project.getId(),
                assignedRole.getId());

        Boolean cached = context.roleMembershipByKey.get(key);
        if (cached != null) {
            return cached;
        }

        boolean member = false;
        try {
            List<UserDto> roleUsers = userManager.findByProjectAndRole(
                    currentUser,
                    project.getId(),
                    assignedRole.getName());
            member = containsUser(roleUsers, currentUser.getId());
        } catch (RuntimeException error) {
            LOGGER.error(
                    "Effective role membership lookup failed for user [{}], "
                            + "project [{}], role [{}]. Access denied.",
                    currentUser.getId(),
                    project.getId(),
                    assignedRole.getId(),
                    error);
        }

        context.roleMembershipByKey.put(key, member);
        return member;
    }

    private Set<Integer> effectiveRoleIds(
            ProjectDto project,
            UserDto currentUser,
            AssignmentAuthorizationContext context) {

        Integer projectId = project.getId();
        Set<Integer> cached = context.effectiveRoleIdsByProject.get(projectId);
        if (cached != null) {
            return cached;
        }

        Set<Integer> roleIds = new HashSet<>();
        try {
            List<RoleDto> roles = projectManager.getProjectMemberRoles(
                    project,
                    currentUser,
                    true);
            if (roles != null) {
                for (RoleDto role : roles) {
                    if (role != null && role.getId() != null) {
                        roleIds.add(role.getId());
                    }
                }
            }
        } catch (RuntimeException error) {
            LOGGER.error(
                    "Project role lookup failed for user [{}], project [{}]. "
                            + "The role-user fallback will still be evaluated.",
                    currentUser.getId(),
                    projectId,
                    error);
        }

        Set<Integer> result = Collections.unmodifiableSet(roleIds);
        context.effectiveRoleIdsByProject.put(projectId, result);
        return result;
    }

    private static boolean containsUser(
            List<UserDto> users,
            Integer expectedUserId) {
        if (users == null || expectedUserId == null) {
            return false;
        }
        for (UserDto user : users) {
            if (user != null && expectedUserId.equals(user.getId())) {
                return true;
            }
        }
        return false;
    }

    private static ProjectManager resolveProjectManager() {
        return applicationContext().getBean(ProjectManager.class);
    }

    private static UserManager resolveUserManager() {
        return applicationContext().getBean(UserManager.class);
    }

    private static ApplicationContext applicationContext() {
        return ApplicationContextHolder.getInstance().getApplicationContext();
    }

    /** Invocation-scoped authorization caches. */
    public static final class AssignmentAuthorizationContext {
        private final Map<Integer, Set<Integer>> effectiveRoleIdsByProject =
                new HashMap<>();
        private final Map<RoleMembershipKey, Boolean> roleMembershipByKey =
                new HashMap<>();
    }

    private static final class RoleMembershipKey {
        private final Integer userId;
        private final Integer projectId;
        private final Integer roleId;

        private RoleMembershipKey(
                Integer userId,
                Integer projectId,
                Integer roleId) {
            this.userId = userId;
            this.projectId = projectId;
            this.roleId = roleId;
        }

        @Override
        public boolean equals(Object value) {
            if (this == value) {
                return true;
            }
            if (!(value instanceof RoleMembershipKey)) {
                return false;
            }
            RoleMembershipKey other = (RoleMembershipKey) value;
            return Objects.equals(userId, other.userId)
                    && Objects.equals(projectId, other.projectId)
                    && Objects.equals(roleId, other.roleId);
        }

        @Override
        public int hashCode() {
            return Objects.hash(userId, projectId, roleId);
        }
    }
}
