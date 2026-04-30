public without sharing class OG_UpdateAppointmentAction {

    private static final String ACTION_CANCEL     = 'cancel';
    private static final String ACTION_RESCHEDULE = 'reschedule';
    private static final String STATUS_CANCELED   = 'Canceled';
    private static final String STATUS_SCHEDULED  = 'Scheduled';

    // ── Input ────────────────────────────────────────────────────
    public class ActionInput {
        @InvocableVariable(label='Input Data' required=true)
        public InputData input;
    }

    public class InputData {
        @AuraEnabled @InvocableVariable(label='Appointment ID' required=true
            description='ServiceAppointment ID from the View Appointments action.')
        public String appointmentId;

        @AuraEnabled @InvocableVariable(label='Action' required=true
            description='Must be "reschedule" or "cancel".')
        public String action;

        @AuraEnabled @InvocableVariable(label='New Date and Time'
            description='Required for reschedule. Format: YYYY-MM-DD HH:MM:SS. Must be future.')
        public String newDateTime;

        @AuraEnabled @InvocableVariable(label='Reason'
            description='Optional reason for the cancellation or reschedule.')
        public String reason;
    }

    // ── Output ───────────────────────────────────────────────────
    public class ActionOutput {
        @InvocableVariable(label='Output Data')
        public OutputData output;
    }

    public class OutputData {
        @AuraEnabled @InvocableVariable(label='Result Message'
            description='Formatted confirmation of the operation.')
        public String resultMessage;

        @AuraEnabled @InvocableVariable(label='Success'
            description='True if completed successfully.')
        public Boolean isSuccess;

        @AuraEnabled @InvocableVariable(label='Error Message'
            description='Error details if failed.')
        public String errorMessage;
    }

    // ── Entry Point ──────────────────────────────────────────────
    @InvocableMethod(
        label='Reschedule or Cancel Appointment'
        description='Cancels or reschedules an existing appointment. For reschedule, performs full slot availability check including operating hours and booking conflicts. Pass Appointment ID and action type.'
        category='Onco Global')
    public static List<ActionOutput> execute(List<ActionInput> inputs) {
        InputData inp = inputs[0].input;
        OutputData outData = new OutputData();

        try {
            System.debug('>>> OG_UpdateAppointmentAction | apptId='
                + inp.appointmentId + ', action=' + inp.action
                + ', newDT=' + inp.newDateTime);

            // Validate ID format
            try { Id validId = (Id) inp.appointmentId.trim(); }
            catch (Exception e) {
                outData.isSuccess = false;
                outData.errorMessage = '"' + inp.appointmentId
                    + '" is not a valid Appointment ID. Use "View Appointments" first.';
                ActionOutput errOut = new ActionOutput();
                errOut.output = outData;
                return new List<ActionOutput>{ errOut };
            }

            ServiceAppointment appt = fetchAppointment(inp.appointmentId);
            if (appt == null) {
                outData.isSuccess = false;
                outData.errorMessage = 'Appointment not found. Please check the ID.';
                ActionOutput errOut = new ActionOutput();
                errOut.output = outData;
                return new List<ActionOutput>{ errOut };
            }

            String act = String.isNotBlank(inp.action)
                ? inp.action.toLowerCase().trim() : '';

            if (act == ACTION_CANCEL) {
                outData = handleCancel(appt, inp.reason);
            } else if (act == ACTION_RESCHEDULE) {
                outData = handleReschedule(appt, inp.newDateTime, inp.reason);
            } else {
                outData.isSuccess = false;
                outData.errorMessage = 'Invalid action "' + inp.action
                    + '". Use "cancel" or "reschedule".';
            }

        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'Error: ' + ex.getMessage()
                + ' | Stack: ' + ex.getStackTraceString());
            outData.isSuccess = false;
            outData.errorMessage = 'Error: ' + ex.getMessage();
        }

        System.debug('<<< isSuccess=' + outData.isSuccess);
        ActionOutput finalOut = new ActionOutput();
        finalOut.output = outData;
        return new List<ActionOutput>{ finalOut };
    }

    // ── Fetch appointment ────────────────────────────────────────
    private static ServiceAppointment fetchAppointment(String apptId) {
        List<ServiceAppointment> rows = [
            SELECT Id, AppointmentNumber, Status, SchedStartTime, SchedEndTime,
                   AccountId, ServiceTerritoryId, WorkTypeId,
                   ServiceTerritory.Name, WorkType.Name,
                   (SELECT ServiceResource.Name, ServiceResourceId
                    FROM ServiceResources)
            FROM ServiceAppointment WHERE Id = :apptId LIMIT 1];
        return rows.isEmpty() ? null : rows[0];
    }

    // ── Cancel handler ───────────────────────────────────────────
    private static OutputData handleCancel(ServiceAppointment a, String reason) {
        System.debug('Cancel — appt #' + a.AppointmentNumber + ', status=' + a.Status);
        OutputData out = new OutputData();

        if (a.Status == STATUS_CANCELED) {
            out.isSuccess = false;
            out.errorMessage = 'Appointment #' + a.AppointmentNumber + ' is already canceled.';
            return out;
        }
        if (a.SchedStartTime < DateTime.now()) {
            out.isSuccess = false;
            out.errorMessage = 'Cannot cancel a past appointment (was on '
                + a.SchedStartTime.format('MMMM d, yyyy h:mm a') + ').';
            return out;
        }

        a.Status = STATUS_CANCELED;
        update a;

        String doc = a.ServiceResources != null && !a.ServiceResources.isEmpty()
                   ? a.ServiceResources[0].ServiceResource.Name : 'Not assigned';
        String hosp = a.ServiceTerritory != null ? a.ServiceTerritory.Name : 'Onco Global';

        out.isSuccess = true;
        out.resultMessage = String.join(new List<String>{
            'APPOINTMENT CANCELED',
            'Appointment # : ' + a.AppointmentNumber,
            'Doctor        : ' + doc,
            'Hospital      : ' + hosp,
            'Was on        : ' + a.SchedStartTime.format('EEEE, MMMM d, yyyy h:mm a'),
            'Reason        : ' + (String.isNotBlank(reason) ? reason : 'Not specified'),
            '',
            'Would you like to book a new appointment?'
        }, '\n');
        System.debug('Cancel SUCCESS');
        return out;
    }

    // ── Reschedule handler ───────────────────────────────────────
    private static OutputData handleReschedule(
            ServiceAppointment a, String newDTStr, String reason) {
        System.debug('Reschedule — appt #' + a.AppointmentNumber);
        OutputData out = new OutputData();

        if (String.isBlank(newDTStr)) {
            out.isSuccess = false;
            out.errorMessage = 'New date and time is required for rescheduling.';
            return out;
        }

        DateTime newStart = DateTime.valueOf(newDTStr.trim().replace('T', ' '));

        if (newStart <= DateTime.now()) {
            out.isSuccess = false;
            out.errorMessage = 'Cannot reschedule to a past time. Choose a future slot.';
            return out;
        }

        if (a.ServiceResources == null || a.ServiceResources.isEmpty()) {
            out.isSuccess = false;
            out.errorMessage = 'No doctor assigned to this appointment.';
            return out;
        }

        Id resourceId = a.ServiceResources[0].ServiceResourceId;
        Long durationMs = a.SchedEndTime.getTime() - a.SchedStartTime.getTime();
        DateTime newEnd = DateTime.newInstance(newStart.getTime() + durationMs);

        // Full 4-step slot availability check
        SlotCheck check = checkSlotAvailability(resourceId, newStart, newEnd, a.Id);
        if (!check.isAvailable) {
            out.isSuccess = false;
            out.errorMessage = check.reason;
            return out;
        }

        DateTime oldStart = a.SchedStartTime;
        DateTime oldEnd = a.SchedEndTime;
        a.SchedStartTime = newStart;
        a.SchedEndTime = newEnd;
        a.Status = STATUS_SCHEDULED;
        update a;

        String doc = a.ServiceResources[0].ServiceResource.Name;
        String hosp = a.ServiceTerritory != null ? a.ServiceTerritory.Name : 'Onco Global';

        out.isSuccess = true;
        out.resultMessage = String.join(new List<String>{
            'APPOINTMENT RESCHEDULED',
            'Appointment # : ' + a.AppointmentNumber,
            'Doctor        : ' + doc,
            'Hospital      : ' + hosp,
            'Previous time : ' + oldStart.format('EEEE, MMMM d, yyyy')
                               + ' at ' + oldStart.format('h:mm a')
                               + ' - ' + oldEnd.format('h:mm a'),
            'New time      : ' + newStart.format('EEEE, MMMM d, yyyy')
                               + ' at ' + newStart.format('h:mm a')
                               + ' - ' + newEnd.format('h:mm a'),
            'Reason        : ' + (String.isNotBlank(reason) ? reason : 'Not specified'),
            '',
            'Please arrive 15 minutes before your new appointment time.'
        }, '\n');
        System.debug('Reschedule SUCCESS');
        return out;
    }

    // ── 4-Step Slot Availability Check ───────────────────────────
    private class SlotCheck {
        Boolean isAvailable;
        String reason;
        SlotCheck(Boolean ok, String msg) { isAvailable = ok; reason = msg; }
    }

    private static SlotCheck checkSlotAvailability(
            Id resourceId, DateTime newStart, DateTime newEnd, Id excludeApptId) {

        // Step 1: Get OperatingHours
        System.debug('Checking Slot Availability for resource: ' + resourceId);
        List<ServiceTerritoryMember> mems = [
            SELECT OperatingHoursId FROM ServiceTerritoryMember
            WHERE ServiceResourceId = :resourceId LIMIT 1];
        if (mems.isEmpty()) {
            System.debug('Failed Step 1: No territory member found.');
            return new SlotCheck(false,
                'Doctor schedule not configured. Contact the hospital directly.');
        }
        System.debug('Found Operating Hours ID: ' + mems[0].OperatingHoursId);

        // Step 2: Check if doctor works on this day
        String dayName = newStart.format('EEEE');
        System.debug('Checking availability for day: ' + dayName);
        List<TimeSlot> daySlots = [
            SELECT StartTime, EndTime FROM TimeSlot
            WHERE OperatingHoursId = :mems[0].OperatingHoursId
            AND DayOfWeek = :dayName AND Type = 'Normal'];
        if (daySlots.isEmpty()) {
            System.debug('Failed Step 2: No time slots found for ' + dayName);
            return new SlotCheck(false,
                'The doctor is not available on ' + dayName
                + 's. Please choose a different day.');
        }

        // Step 3: Check if time is within any valid working hour block (shift)
        Date newDate = newStart.date();
        Boolean fitsInShift = false;
        String validHoursStr = '';

        for (TimeSlot ts : daySlots) {
            DateTime ohStart = DateTime.newInstance(newDate, ts.StartTime);
            DateTime ohEnd = DateTime.newInstance(newDate, ts.EndTime);
            
            validHoursStr += ohStart.format('h:mm a') + ' – ' + ohEnd.format('h:mm a') + ', ';

            if (newStart >= ohStart && newEnd <= ohEnd) {
                fitsInShift = true;
                System.debug('Found valid shift: ' + ts.StartTime + ' - ' + ts.EndTime);
                break;
            }
        }

        if (!fitsInShift) {
            validHoursStr = validHoursStr.removeEnd(', ');
            return new SlotCheck(false,
                'Requested time is outside working hours or during a break. Valid hours are: '
                + validHoursStr + '. Please choose a valid slot.');
        }

        // Step 4: Check booking conflicts
        List<AssignedResource> conflicts = [
            SELECT Id FROM AssignedResource
            WHERE ServiceResourceId = :resourceId
            AND ServiceAppointment.Id != :excludeApptId
            AND ServiceAppointment.SchedStartTime < :newEnd
            AND ServiceAppointment.SchedEndTime > :newStart
            AND ServiceAppointment.Status NOT IN ('Canceled', 'Cannot Complete')
            LIMIT 1];
        if (!conflicts.isEmpty()) {
            return new SlotCheck(false,
                'That slot is already booked. Choose a different time.');
        }

        return new SlotCheck(true, null);
    }
}