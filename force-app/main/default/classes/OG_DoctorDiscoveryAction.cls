/**
 * @description Agentforce Action — Doctor & Slot Discovery
 *              Handles: getSpecialties, getLocations, findDoctors
 *              Finds doctors by specialty + city + date with available time slots.
 *              All queries are dynamic — no hardcoded facility names or countries.
 * @author      Onco Global Dev Team
 * @date        2026-04-22
 */
public without sharing class OG_DoctorDiscoveryAction {

    private static final String ACTION_GET_SPECIALTIES = 'getspecialties';
    private static final String ACTION_GET_LOCATIONS   = 'getlocations';
    private static final String ACTION_FIND_DOCTORS    = 'finddoctors';
    private static final Integer SLOT_DURATION_MINUTES = 30;

    public class Request {
        @InvocableVariable(label='Action Type' description='getSpecialties, getLocations, or findDoctors' required=true)
        public String actionType;
        @InvocableVariable(label='Specialty Name' description='Specialty to search for')
        public String specialtyName;
        @InvocableVariable(label='City Name' description='City to search in')
        public String cityName;
        @InvocableVariable(label='Preferred Date' description='Date in YYYY-MM-DD format')
        public String preferredDate;
        @InvocableVariable(label='Search Keyword' description='Optional keyword filter')
        public String searchKeyword;
    }

    public class Response {
        @InvocableVariable(label='Result List')
        public String resultList;
        @InvocableVariable(label='Result Count')
        public Integer resultCount;
        @InvocableVariable(label='Available Cities')
        public String availableCities;
        @InvocableVariable(label='Alternative Cities')
        public String alternativeCities;
        @InvocableVariable(label='Message')
        public String message;
    }

    @InvocableMethod(label='OG Doctor Discovery' description='Find specialties, locations, or doctors with slots. actionType: getSpecialties, getLocations, or findDoctors.' category='Onco Global')
    public static List<Response> execute(List<Request> requests) {
        System.debug('OG_DoctorDiscoveryAction invoked with ' + requests.size() + ' request(s)');
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            System.debug('Action: ' + req.actionType + ' | Specialty: ' + req.specialtyName + ' | City: ' + req.cityName + ' | Date: ' + req.preferredDate);
            String action = String.isNotBlank(req.actionType) ? req.actionType.trim().toLowerCase() : '';
            if (action == ACTION_GET_SPECIALTIES) {
                responses.add(getSpecialties(req));
            } else if (action == ACTION_GET_LOCATIONS) {
                responses.add(getLocations(req));
            } else if (action == ACTION_FIND_DOCTORS) {
                responses.add(findDoctors(req));
            } else {
                Response res = new Response();
                res.resultCount = 0;
                res.message = 'Invalid action. Use "getSpecialties", "getLocations", or "findDoctors".';
                System.debug('Invalid action type: ' + req.actionType);
                responses.add(res);
            }
        }
        return responses;
    }

    // ── Get Specialties ────────────────────────────────────────
    private static Response getSpecialties(Request req) {
        Response res = new Response();
        List<CareSpecialty> specs;

        if (String.isNotBlank(req.searchKeyword)) {
            String kw = '%' + req.searchKeyword.trim() + '%';
            specs = [SELECT Name, Description FROM CareSpecialty WHERE IsActive = true AND (Name LIKE :kw OR Description LIKE :kw) ORDER BY Name];
            System.debug('Queried specialties with keyword: ' + req.searchKeyword + ' → ' + specs.size() + ' results');
        } else {
            specs = [SELECT Name, Description FROM CareSpecialty WHERE IsActive = true ORDER BY Name];
            System.debug('Queried all active specialties → ' + specs.size() + ' results');
        }

        res.resultCount = specs.size();
        if (specs.isEmpty()) {
            res.message = 'No specialties found.';
            res.resultList = '';
            return res;
        }

        List<String> lines = new List<String>();
        for (CareSpecialty cs : specs) {
            String specDesc = String.isNotBlank(cs.Description) ? ' — ' + cs.Description : '';
            lines.add('• ' + cs.Name + specDesc);
        }
        res.resultList = String.join(lines, '\n');
        res.message = 'Found ' + specs.size() + ' specialties.';
        return res;
    }

    // ── Get Locations ──────────────────────────────────────────
    private static Response getLocations(Request req) {
        Response res = new Response();

        // Dynamic query — no hardcoded facility prefix
        List<HealthcareFacility> facilities;
        if (String.isNotBlank(req.cityName)) {
            String city = req.cityName.trim();
            facilities = [
                SELECT Name, Account.Name, Account.BillingStreet,
                       Account.BillingCity, Account.BillingState, Account.Phone
                FROM HealthcareFacility
                WHERE Account.BillingCity = :city
                ORDER BY Name
            ];
            System.debug('Queried facilities in ' + city + ' → ' + facilities.size() + ' results');
        } else {
            facilities = [
                SELECT Name, Account.Name, Account.BillingStreet,
                       Account.BillingCity, Account.BillingState, Account.Phone
                FROM HealthcareFacility
                ORDER BY Account.BillingCity, Name
            ];
            System.debug('Queried all active facilities → ' + facilities.size() + ' results');
        }

        // Dynamically collect all available cities
        Set<String> citySet = new Set<String>();
        for (HealthcareFacility f : [
            SELECT Account.BillingCity FROM HealthcareFacility
            WHERE Account.BillingCity != null
        ]) {
            citySet.add(f.Account.BillingCity);
        }
        res.availableCities = String.join(new List<String>(citySet), ', ');
        System.debug('Available cities: ' + res.availableCities);

        res.resultCount = facilities.size();
        if (facilities.isEmpty()) {
            res.message = 'No facilities found'
                + (String.isNotBlank(req.cityName) ? ' in ' + req.cityName : '')
                + '. Available cities: ' + res.availableCities;
            res.resultList = '';
            return res;
        }

        List<String> lines = new List<String>();
        for (HealthcareFacility hf : facilities) {
            String entry = '• ' + hf.Name;
            if (hf.Account != null) {
                List<String> addressParts = new List<String>();
                if (String.isNotBlank(hf.Account.BillingStreet)) addressParts.add(hf.Account.BillingStreet);
                if (String.isNotBlank(hf.Account.BillingCity)) addressParts.add(hf.Account.BillingCity);
                if (String.isNotBlank(hf.Account.BillingState)) addressParts.add(hf.Account.BillingState);
                if (!addressParts.isEmpty()) {
                    entry += '\n  Address: ' + String.join(addressParts, ', ');
                }
                if (String.isNotBlank(hf.Account.Phone)) {
                    entry += '\n  Phone: ' + hf.Account.Phone;
                }
            }
            lines.add(entry);
        }
        res.resultList = String.join(lines, '\n');
        res.message = 'Found ' + facilities.size() + ' facilities.';
        return res;
    }

    // ── Find Doctors ───────────────────────────────────────────
    private static Response findDoctors(Request req) {
        Response res = new Response();
        res.resultCount = 0;

        if (String.isBlank(req.specialtyName)) {
            res.message = 'Please specify a specialty or describe your symptoms.';
            System.debug('findDoctors called without specialty');
            return res;
        }
        if (String.isBlank(req.cityName)) {
            res.message = 'Please specify your preferred city.';
            System.debug('findDoctors called without city');
            return res;
        }

        Date targetDate;
        try {
            targetDate = String.isNotBlank(req.preferredDate) ? Date.valueOf(req.preferredDate) : Date.today();
        } catch (Exception e) {
            targetDate = Date.today();
            System.debug('Invalid date format, defaulting to today: ' + req.preferredDate);
        }

        DateTime targetDT = DateTime.newInstance(targetDate, Time.newInstance(0, 0, 0, 0));
        String dayOfWeek = targetDT.format('EEEE');
        String targetCity = req.cityName.trim();
        System.debug('Finding doctors — Specialty: ' + req.specialtyName + ' | City: ' + targetCity + ' | Date: ' + targetDate + ' | Day: ' + dayOfWeek);

        // Step 1: Find specialty
        String specSearch = '%' + req.specialtyName.trim() + '%';
        List<CareSpecialty> specialties = [
            SELECT Id, Name FROM CareSpecialty
            WHERE IsActive = true AND Name LIKE :specSearch LIMIT 5
        ];
        System.debug('Step 1 — Specialties found: ' + specialties.size());
        if (specialties.isEmpty()) {
            res.message = 'No specialty found matching "' + req.specialtyName + '". Please check available specialties.';
            return res;
        }

        Set<Id> specIds = new Set<Id>();
        for (CareSpecialty cs : specialties) {
            specIds.add(cs.Id);
            System.debug('  Matched specialty: ' + cs.Name + ' (Id: ' + cs.Id + ')');
        }

        // Step 2: Find practitioner-facility-specialty links
        List<CareProviderFacilitySpecialty> cpfsList = [
            SELECT PractitionerFacilityId FROM CareProviderFacilitySpecialty
            WHERE SpecialtyId IN :specIds AND IsActive = true
        ];
        System.debug('Step 2 — CareProviderFacilitySpecialty records: ' + cpfsList.size());
        if (cpfsList.isEmpty()) {
            res.message = 'No doctors assigned to this specialty.';
            return res;
        }

        Set<Id> hpfIds = new Set<Id>();
        for (CareProviderFacilitySpecialty cpfs : cpfsList) {
            hpfIds.add(cpfs.PractitionerFacilityId);
        }

        // Step 3: Get facility details, filter by city — fully dynamic
        List<HealthcarePractitionerFacility> hpfs = [
            SELECT Id, PractitionerId, HealthcareFacility.Name, HealthcareFacility.Account.BillingCity
            FROM HealthcarePractitionerFacility
            WHERE Id IN :hpfIds AND IsActive = true
        ];
        System.debug('Step 3 — PractitionerFacility records: ' + hpfs.size());

        Set<Id> matchedContactIds = new Set<Id>();
        Map<Id, String> contactToFacility = new Map<Id, String>();
        Set<String> allCitiesWithSpec = new Set<String>();

        for (HealthcarePractitionerFacility hpf : hpfs) {
            String city = hpf.HealthcareFacility?.Account?.BillingCity;
            if (city != null) allCitiesWithSpec.add(city);
            if (city != null && city.equalsIgnoreCase(targetCity)) {
                matchedContactIds.add(hpf.PractitionerId);
                contactToFacility.put(hpf.PractitionerId, hpf.HealthcareFacility.Name);
            }
        }
        System.debug('Step 3 — Matched doctors in ' + targetCity + ': ' + matchedContactIds.size() + ' | All cities with specialty: ' + allCitiesWithSpec);

        if (matchedContactIds.isEmpty()) {
            allCitiesWithSpec.remove(targetCity);
            res.alternativeCities = String.join(new List<String>(allCitiesWithSpec), ', ');

            // Get hospital names in alternative cities for better context
            List<String> altDetails = new List<String>();
            if (!allCitiesWithSpec.isEmpty()) {
                for (HealthcarePractitionerFacility hpf : hpfs) {
                    String city = hpf.HealthcareFacility?.Account?.BillingCity;
                    String facName = hpf.HealthcareFacility?.Name;
                    if (city != null && allCitiesWithSpec.contains(city) && facName != null) {
                        String detail = facName + ' (' + city + ')';
                        if (!altDetails.contains(detail)) {
                            altDetails.add(detail);
                        }
                    }
                }
            }

            // Also get all available cities with any hospitals
            Set<String> allAvailCities = new Set<String>();
            for (HealthcareFacility hf : [
                SELECT Account.BillingCity FROM HealthcareFacility
                WHERE Account.BillingCity != null
            ]) {
                allAvailCities.add(hf.Account.BillingCity);
            }
            res.availableCities = String.join(new List<String>(allAvailCities), ', ');

            res.message = 'No doctors found for this specialty in ' + targetCity + '.';
            if (!altDetails.isEmpty()) {
                res.message += ' This specialty is available at: ' + String.join(altDetails, ', ') + '.';
            }
            if (String.isNotBlank(res.availableCities)) {
                res.message += ' All available cities: ' + res.availableCities + '.';
            }
            res.message += ' Would you like to try a different city or date?';
            System.debug('No doctors in ' + targetCity + ' | Alternatives: ' + altDetails + ' | All cities: ' + res.availableCities);
            return res;
        }

        // Step 4: Get doctor details
        Map<Id, Contact> contactMap = new Map<Id, Contact>([
            SELECT Id, FirstName, LastName, Title FROM Contact WHERE Id IN :matchedContactIds
        ]);
        System.debug('Step 4 — Doctor contacts loaded: ' + contactMap.size());

        // Step 5: Map to ServiceResources
        Set<String> srNames = new Set<String>();
        Map<String, Id> srNameToContactId = new Map<String, Id>();
        for (Contact doc : contactMap.values()) {
            String srName = 'SR_' + doc.FirstName + '_' + doc.LastName;
            srNames.add(srName);
            srNameToContactId.put(srName, doc.Id);
        }

        Map<String, ServiceResource> srByName = new Map<String, ServiceResource>();
        for (ServiceResource sr : [
            SELECT Id, Name FROM ServiceResource WHERE Name IN :srNames AND IsActive = true
        ]) {
            srByName.put(sr.Name, sr);
        }
        System.debug('Step 5 — ServiceResources matched: ' + srByName.size());

        // Step 6: Get territory memberships with operating hours
        Set<Id> srIds = new Set<Id>();
        for (ServiceResource sr : srByName.values()) {
            srIds.add(sr.Id);
        }

        Map<Id, Id> srIdToOHId = new Map<Id, Id>();
        for (ServiceTerritoryMember stm : [
            SELECT ServiceResourceId, OperatingHoursId FROM ServiceTerritoryMember
            WHERE ServiceResourceId IN :srIds AND EffectiveStartDate <= :targetDate AND OperatingHoursId != null
        ]) {
            srIdToOHId.put(stm.ServiceResourceId, stm.OperatingHoursId);
        }
        System.debug('Step 6 — Territory members with OH: ' + srIdToOHId.size());

        // Step 7: Get TimeSlots for the day
        Set<Id> ohIds = new Set<Id>(srIdToOHId.values());
        Map<Id, List<TimeSlot>> ohToSlots = new Map<Id, List<TimeSlot>>();
        for (TimeSlot ts : [
            SELECT OperatingHoursId, StartTime, EndTime FROM TimeSlot
            WHERE OperatingHoursId IN :ohIds AND DayOfWeek = :dayOfWeek ORDER BY StartTime
        ]) {
            if (!ohToSlots.containsKey(ts.OperatingHoursId)) {
                ohToSlots.put(ts.OperatingHoursId, new List<TimeSlot>());
            }
            ohToSlots.get(ts.OperatingHoursId).add(ts);
        }
        System.debug('Step 7 — TimeSlots loaded for ' + ohToSlots.size() + ' operating hours');

        // Step 8: Get existing bookings
        DateTime dayStart = DateTime.newInstance(targetDate, Time.newInstance(0, 0, 0, 0));
        DateTime dayEnd = DateTime.newInstance(targetDate, Time.newInstance(23, 59, 59, 0));

        Map<Id, Set<String>> srBookedTimes = new Map<Id, Set<String>>();
        for (AssignedResource ar : [
            SELECT ServiceResourceId, ServiceAppointment.SchedStartTime
            FROM AssignedResource WHERE ServiceResourceId IN :srIds
            AND ServiceAppointment.SchedStartTime >= :dayStart AND ServiceAppointment.SchedStartTime <= :dayEnd
            AND ServiceAppointment.Status NOT IN ('Canceled', 'Cannot Complete')
        ]) {
            if (!srBookedTimes.containsKey(ar.ServiceResourceId)) {
                srBookedTimes.put(ar.ServiceResourceId, new Set<String>());
            }
            DateTime bk = ar.ServiceAppointment.SchedStartTime;
            srBookedTimes.get(ar.ServiceResourceId).add(formatTime(bk.hour(), bk.minute()));
        }
        System.debug('Step 8 — Booked slots found for ' + srBookedTimes.size() + ' resource(s)');

        // Step 9: Build available slots per doctor
        DateTime nowDT = DateTime.now();
        List<String> doctorResults = new List<String>();

        for (String srName : srByName.keySet()) {
            ServiceResource sr = srByName.get(srName);
            Id contactId = srNameToContactId.get(srName);
            if (contactId == null) continue;
            Contact doc = contactMap.get(contactId);
            if (doc == null) continue;

            Id ohId = srIdToOHId.get(sr.Id);
            List<TimeSlot> slots = (ohId != null) ? ohToSlots.get(ohId) : null;

            List<String> availableSlots = new List<String>();
            if (slots != null) {
                Set<String> booked = srBookedTimes.containsKey(sr.Id) ? srBookedTimes.get(sr.Id) : new Set<String>();
                for (TimeSlot ts : slots) {
                    Integer startMin = ts.StartTime.hour() * 60 + ts.StartTime.minute();
                    Integer endMin = ts.EndTime.hour() * 60 + ts.EndTime.minute();
                    for (Integer m = startMin; m + SLOT_DURATION_MINUTES <= endMin; m += SLOT_DURATION_MINUTES) {
                        Integer hr = m / 60;
                        Integer mn = Math.mod(m, 60);
                        String slotLabel = formatTime(hr, mn);
                        // Skip past times for today
                        if (targetDate == Date.today()) {
                            DateTime slotDT = DateTime.newInstance(targetDate, Time.newInstance(hr, mn, 0, 0));
                            if (slotDT <= nowDT) continue;
                        }
                        if (!booked.contains(slotLabel)) availableSlots.add(slotLabel);
                    }
                }
            }

            System.debug('Step 9 — Dr. ' + doc.FirstName + ' ' + doc.LastName + ': ' + availableSlots.size() + ' available slot(s)');

            if (!availableSlots.isEmpty()) {
                String facility = contactToFacility.get(contactId);
                String entry = 'Dr. ' + doc.FirstName + ' ' + doc.LastName;
                if (String.isNotBlank(doc.Title)) entry += ' (' + doc.Title + ')';
                entry += '\n   Facility: ' + (facility != null ? facility : targetCity);
                entry += '\n   Available Slots: ' + String.join(availableSlots, ', ');
                entry += '\n   Earliest: ' + availableSlots[0];
                doctorResults.add(entry);
            }
        }

        res.resultCount = doctorResults.size();
        if (doctorResults.isEmpty()) {
            allCitiesWithSpec.remove(targetCity);
            res.alternativeCities = String.join(new List<String>(allCitiesWithSpec), ', ');
            res.message = 'No available slots in ' + targetCity + ' on ' + targetDate.format() + '.';
            if (String.isNotBlank(res.alternativeCities)) res.message += ' Try: ' + res.alternativeCities;
            res.resultList = '';
            System.debug('No available slots — alternatives: ' + res.alternativeCities);
        } else {
            res.resultList = String.join(doctorResults, '\n\n');
            res.message = 'Found ' + doctorResults.size() + ' doctor(s) in ' + targetCity + ' on ' + targetDate.format() + '.';
            System.debug('✅ Found ' + doctorResults.size() + ' doctor(s) with available slots');
        }
        return res;
    }

    private static String formatTime(Integer hour, Integer minute) {
        String period = hour >= 12 ? 'PM' : 'AM';
        Integer displayHour = Math.mod(hour, 12);
        if (displayHour == 0) displayHour = 12;
        String minStr = minute < 10 ? '0' + minute : String.valueOf(minute);
        return displayHour + ':' + minStr + ' ' + period;
    }
}