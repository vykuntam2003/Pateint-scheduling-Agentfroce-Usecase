/**
 * @description Invocable Action to send appointment emails.
 *              Supports CONFIRMATION, UPDATE, CANCELLATION, REMINDER.
 */
public without sharing class OG_SendAppointmentEmailAction {

    public class ActionInput {
        @InvocableVariable(label='Appointment ID' required=true)
        public String appointmentId;

        @InvocableVariable(label='Email Type' required=true 
            description='Choose: CONFIRMATION, RESCHEDULE, CANCELLATION, REMINDER')
        public String emailType;
    }

    @InvocableMethod(label='Send Appointment Email' category='Onco Global')
    public static void execute(List<ActionInput> inputs) {
        for (ActionInput inp : inputs) {
            try {
                OG_EmailService.EmailType type = OG_EmailService.EmailType.valueOf(inp.emailType.toUpperCase());
                OG_EmailService.sendAppointmentEmail((Id)inp.appointmentId, type);
            } catch (Exception e) {
                System.debug('Error in OG_SendAppointmentEmailAction: ' + e.getMessage());
            }
        }
    }
}