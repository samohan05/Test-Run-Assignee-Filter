package com.philips.cb.testrun;

import com.intland.codebeamer.manager.testmanagement.TestRun;
import com.intland.codebeamer.persistence.dto.TrackerItemDto;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpSession;
import java.net.URI;
import java.net.URISyntaxException;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

/**
 * Preserves Assignment Board strict-single-run scope throughout the native
 * Test Runner lifecycle while leaving normal parent Test Run execution as a
 * multi-run operation.
 */
public final class SingleRunFilterAspect {

    public static final String STRICT_SINGLE_RUN_ID = "strictSingleRunId";
    private static final String TASK_ID = "task_id";
    private static final String RUNNER_PATH = "/testset/testRunner.spr";
    private static final String SESSION_PREFIX =
            SingleRunFilterAspect.class.getName() + ".scope.";
    private static final long SCOPE_TTL_MILLIS = 30L * 60L * 1000L;

    private static final Logger LOGGER =
            LogManager.getLogger(SingleRunFilterAspect.class);

    private SingleRunFilterAspect() {
        // Utility class.
    }

    public static List<TestRun> applyToAuthorizedRuns(
            List<TestRun> authorizedRuns) {

        List<TestRun> safeRuns = authorizedRuns == null
                ? Collections.emptyList()
                : authorizedRuns;

        HttpServletRequest request = currentRequest();
        if (request == null) {
            return safeRuns;
        }

        StrictRunSelection selection = resolveStrictSelection(request);
        if (selection == null) {
            return safeRuns;
        }

        List<TestRun> selected = new ArrayList<>(1);
        for (TestRun run : safeRuns) {
            TrackerItemDto item = run == null ? null : run.getDelegate();
            if (item != null && selection.runId.equals(item.getId())) {
                selected.add(run);
                break;
            }
        }

        if (selected.isEmpty()) {
            LOGGER.warn(
                    "Strict run [{}] from [{}] is not present in the assignment-"
                            + "authorized collection for task [{}].",
                    selection.runId,
                    selection.source,
                    selection.taskId);
        }
        return selected;
    }

    static StrictRunSelection resolveStrictSelection(
            HttpServletRequest request) {

        Integer taskId = parsePositiveInteger(request.getParameter(TASK_ID));
        Integer directId = parsePositiveInteger(
                request.getParameter(STRICT_SINGLE_RUN_ID));

        if (directId != null) {
            storeScope(request, taskId, directId);
            return new StrictRunSelection(taskId, directId, "request-parameter");
        }

        Integer urlId = parseStrictIdFromUrl(request.getRequestURL() == null
                ? null
                : appendQuery(
                        request.getRequestURL().toString(),
                        request.getQueryString()));
        if (urlId != null) {
            storeScope(request, taskId, urlId);
            return new StrictRunSelection(taskId, urlId, "request-url");
        }

        String referer = request.getHeader("Referer");
        Integer refererId = parseStrictIdFromUrl(referer);
        if (refererId != null) {
            storeScope(request, taskId, refererId);
            return new StrictRunSelection(taskId, refererId, "referer");
        }

        boolean runnerContinuation = isRunnerUrl(referer);
        if (runnerContinuation) {
            StrictRunScope scope = loadScope(request, taskId);
            if (scope != null) {
                return new StrictRunSelection(
                        taskId,
                        scope.runId,
                        "session-continuation");
            }
        } else {
            clearScope(request, taskId);
        }

        return null;
    }

    static Integer parseStrictIdFromUrl(String url) {
        if (url == null || url.trim().isEmpty()) {
            return null;
        }
        try {
            URI uri = new URI(url);
            String query = uri.getRawQuery();
            if (query == null) {
                return null;
            }
            for (String pair : query.split("&")) {
                int separator = pair.indexOf('=');
                String rawName = separator < 0 ? pair : pair.substring(0, separator);
                String rawValue = separator < 0 ? "" : pair.substring(separator + 1);
                String name = URLDecoder.decode(
                        rawName,
                        StandardCharsets.UTF_8.name());
                if (STRICT_SINGLE_RUN_ID.equals(name)) {
                    return parsePositiveInteger(URLDecoder.decode(
                            rawValue,
                            StandardCharsets.UTF_8.name()));
                }
            }
        } catch (Exception error) {
            LOGGER.debug("Unable to parse strict run ID from URL [{}].", url);
        }
        return null;
    }

    static Integer parsePositiveInteger(String value) {
        if (value == null || value.trim().isEmpty()) {
            return null;
        }
        try {
            int parsed = Integer.parseInt(value.trim());
            return parsed > 0 ? parsed : null;
        } catch (NumberFormatException error) {
            return null;
        }
    }

    private static void storeScope(
            HttpServletRequest request,
            Integer taskId,
            Integer runId) {
        if (taskId == null || runId == null) {
            return;
        }
        request.getSession(true).setAttribute(
                sessionKey(taskId),
                new StrictRunScope(runId, System.currentTimeMillis()));
    }

    private static StrictRunScope loadScope(
            HttpServletRequest request,
            Integer taskId) {
        if (taskId == null) {
            return null;
        }
        HttpSession session = request.getSession(false);
        if (session == null) {
            return null;
        }
        Object value = session.getAttribute(sessionKey(taskId));
        if (!(value instanceof StrictRunScope)) {
            return null;
        }
        StrictRunScope scope = (StrictRunScope) value;
        if (System.currentTimeMillis() - scope.createdAt > SCOPE_TTL_MILLIS) {
            session.removeAttribute(sessionKey(taskId));
            return null;
        }
        return scope;
    }

    private static void clearScope(
            HttpServletRequest request,
            Integer taskId) {
        if (taskId == null) {
            return;
        }
        HttpSession session = request.getSession(false);
        if (session != null) {
            session.removeAttribute(sessionKey(taskId));
        }
    }

    private static String sessionKey(Integer taskId) {
        return SESSION_PREFIX + taskId;
    }

    private static boolean isRunnerUrl(String url) {
        if (url == null || url.trim().isEmpty()) {
            return false;
        }
        try {
            return new URI(url).getPath().endsWith(RUNNER_PATH);
        } catch (URISyntaxException error) {
            return url.contains(RUNNER_PATH);
        }
    }

    private static String appendQuery(String url, String query) {
        if (query == null || query.isEmpty()) {
            return url;
        }
        return url + (url.contains("?") ? "&" : "?") + query;
    }

    private static HttpServletRequest currentRequest() {
        if (!(RequestContextHolder.getRequestAttributes()
                instanceof ServletRequestAttributes)) {
            return null;
        }
        return ((ServletRequestAttributes)
                RequestContextHolder.getRequestAttributes()).getRequest();
    }

    static final class StrictRunSelection {
        private final Integer taskId;
        private final Integer runId;
        private final String source;

        private StrictRunSelection(
                Integer taskId,
                Integer runId,
                String source) {
            this.taskId = taskId;
            this.runId = runId;
            this.source = source;
        }
    }

    private static final class StrictRunScope
            implements java.io.Serializable {
        private static final long serialVersionUID = 1L;
        private final Integer runId;
        private final long createdAt;

        private StrictRunScope(Integer runId, long createdAt) {
            this.runId = runId;
            this.createdAt = createdAt;
        }
    }
}
