
package com.intland.codebeamer.controller.testmanagement;

import com.intland.codebeamer.controller.AbstractJsonController;
import com.intland.codebeamer.controller.ApplicationContextHolder;
import com.intland.codebeamer.controller.ControllerUtils;
import com.intland.codebeamer.manager.AccessRightsException;
import com.intland.codebeamer.manager.TrackerItemManager;
import com.intland.codebeamer.manager.testmanagement.TestRun;
import com.intland.codebeamer.persistence.dto.TrackerItemDto;
import com.intland.codebeamer.persistence.dto.UserDto;
import com.intland.codebeamer.security.BaselineInRequest;
import jakarta.servlet.http.HttpServletRequest;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestMethod;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseBody;
import org.springframework.web.server.ResponseStatusException;

/**
 * Returns actual authorized child Test Run IDs for the Execute Run widget.
 *
 * TestRun.getTestCaseRunsRecursively() is already woven by
 * AssignedRunFilterAspect, so the returned collection contains direct-user,
 * effective-role (including group-inherited roles), and unassigned runs.
 */
@Controller
public class PhilipsAuthorizedChildrenController extends AbstractJsonController {
    private static final Logger log =
            LogManager.getLogger(PhilipsAuthorizedChildrenController.class);

    static {
        log.info("PhilipsAuthorizedChildrenController v17.2 class loaded");
    }

    @Override
    protected Logger getLogger() {
        return log;
    }

    @Autowired
    private TrackerItemManager trackerItemManager;

    @RequestMapping(
            value = {"/testRun/philips/authorizedChildren"},
            method = {RequestMethod.GET},
            produces = {"application/json"})
    @ResponseBody
    public Map<String, Object> authorizedChildren(
            HttpServletRequest request,
            @RequestParam("parentId") Integer parentId) throws AccessRightsException {

        UserDto user = ControllerUtils.getCurrentUser(request);
        if (user == null) {
            throw new ResponseStatusException(
                    HttpStatus.UNAUTHORIZED,
                    "Codebeamer session is not authenticated");
        }
        if (parentId == null || parentId.intValue() <= 0) {
            throw new ResponseStatusException(
                    HttpStatus.BAD_REQUEST,
                    "A positive parentId is required");
        }

        TrackerItemDto parentItem = trackerItemManager.findById(user, parentId);
        if (parentItem == null) {
            throw new AccessRightsException(
                    "Parent Test Run with id #" + parentId +
                            " is not found or inaccessible");
        }

        Integer baselineId = BaselineInRequest.get(request).getBaselineId();
        TestRun parentRun = TestRun.cast(
                parentItem,
                user,
                ApplicationContextHolder.getInstance().getApplicationContext(),
                baselineId);

        if (parentRun == null) {
            throw new ResponseStatusException(
                    HttpStatus.BAD_REQUEST,
                    "Item #" + parentId + " is not a Test Run");
        }

        // This method is woven with AssignedRunFilterAspect. The endpoint
        // request has no strictSingleRunId, so SingleRunFilterAspect returns
        // the complete assignee-authorized collection unchanged.
        List<TestRun> authorizedRuns = parentRun.getTestCaseRunsRecursively();
        List<Integer> authorizedIds = new ArrayList<>();

        if (authorizedRuns != null) {
            for (TestRun run : authorizedRuns) {
                TrackerItemDto child = run == null ? null : run.getDelegate();
                if (child != null && child.getId() != null &&
                        !child.getId().equals(parentId)) {
                    authorizedIds.add(child.getId());
                }
            }
        }

        Map<String, Object> response = new LinkedHashMap<>();
        response.put("parentId", parentId);
        response.put("authorizedChildIds", authorizedIds);
        response.put("authorizationMode", "ASSIGNED_RUN_ASPECT");
        response.put("sourceType", "CHILD_TEST_RUN_IDS");

        log.info(
                "Authorized children v17.2: user [{}], parent [{}], child run IDs {}",
                user.getId(), parentId, authorizedIds);
        return response;
    }
}
