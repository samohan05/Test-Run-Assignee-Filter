package com.intland.codebeamer.controller.testmanagement;

import com.intland.codebeamer.controller.AbstractJsonController;
import com.intland.codebeamer.controller.ControllerUtils;
import com.intland.codebeamer.persistence.dto.UserDto;
import jakarta.servlet.http.HttpServletRequest;
import java.util.LinkedHashMap;
import java.util.Map;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestMethod;
import org.springframework.web.bind.annotation.ResponseBody;
import org.springframework.web.server.ResponseStatusException;

@Controller
public class PhilipsCurrentUserController extends AbstractJsonController {

    private static final Logger LOGGER =
            LogManager.getLogger(PhilipsCurrentUserController.class);

    @Override
    protected Logger getLogger() {
        return LOGGER;
    }

    @RequestMapping(
            value = "/testRun/philips/currentUser",
            method = RequestMethod.GET,
            produces = "application/json")
    @ResponseBody
    public Map<String, Object> currentUser(HttpServletRequest request) {
        UserDto user = ControllerUtils.getCurrentUser(request);
        if (user == null) {
            throw new ResponseStatusException(
                    HttpStatus.UNAUTHORIZED,
                    "Codebeamer session is not authenticated");
        }

        Map<String, Object> response = new LinkedHashMap<>();
        response.put("id", user.getId());
        response.put("name", user.getName());
        response.put("firstName", user.getFirstName());
        response.put("lastName", user.getLastName());
        response.put("type", "UserReference");
        return response;
    }
}
