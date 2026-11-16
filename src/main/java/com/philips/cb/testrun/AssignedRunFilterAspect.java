package com.philips.cb.testrun;

import com.intland.codebeamer.manager.testmanagement.TestRun;
import com.intland.codebeamer.persistence.dto.UserDto;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.aspectj.lang.ProceedingJoinPoint;
import org.aspectj.lang.annotation.Around;
import org.aspectj.lang.annotation.Aspect;
import org.aspectj.lang.annotation.Pointcut;

/** Applies assignment authorization, followed by strict one-run selection. */
@Aspect
public class AssignedRunFilterAspect {

    private static final Logger LOGGER =
            LogManager.getLogger(AssignedRunFilterAspect.class);

    private static final EffectiveAssignmentAuthorizationService
            AUTHORIZATION_SERVICE =
                    new EffectiveAssignmentAuthorizationService();

    @Pointcut(
            "execution(public java.util.List "
                    + "com.intland.codebeamer.manager.testmanagement.TestRun."
                    + "getTestCaseRunsRecursively())")
    public void testCaseRunsRecursively() {
        // Pointcut declaration.
    }

    @Around("testCaseRunsRecursively()")
    public Object filterRecursiveRuns(ProceedingJoinPoint joinPoint)
            throws Throwable {

        Object result = joinPoint.proceed();
        if (!(result instanceof List<?>)) {
            return result;
        }

        try {
            List<TestRun> allRuns = testRuns((List<?>) result);
            UserDto currentUser = currentUserOf(joinPoint.getThis());
            if (currentUser == null) {
                return Collections.emptyList();
            }

            EffectiveAssignmentAuthorizationService
                    .AssignmentAuthorizationContext context =
                    new EffectiveAssignmentAuthorizationService
                            .AssignmentAuthorizationContext();

            List<TestRun> authorizedRuns = new ArrayList<>(allRuns.size());
            for (TestRun run : allRuns) {
                if (AUTHORIZATION_SERVICE.isAuthorized(
                        run,
                        currentUser,
                        context)) {
                    authorizedRuns.add(run);
                }
            }

            return SingleRunFilterAspect.applyToAuthorizedRuns(authorizedRuns);
        } catch (RuntimeException error) {
            LOGGER.error(
                    "Assignment authorization failed. No Test Runs returned.",
                    error);
            return Collections.emptyList();
        }
    }

    private static List<TestRun> testRuns(List<?> values) {
        List<TestRun> runs = new ArrayList<>(values.size());
        for (Object value : values) {
            if (value instanceof TestRun) {
                runs.add((TestRun) value);
            }
        }
        return runs;
    }

    private static UserDto currentUserOf(Object target) {
        if (!(target instanceof TestRun)) {
            return null;
        }
        try {
            Field field = TestRun.class.getDeclaredField("user");
            field.setAccessible(true);
            Object value = field.get(target);
            return value instanceof UserDto ? (UserDto) value : null;
        } catch (ReflectiveOperationException | SecurityException error) {
            LOGGER.warn(
                    "Unable to resolve TestRun.user: {}",
                    error.toString());
            return null;
        }
    }
}
