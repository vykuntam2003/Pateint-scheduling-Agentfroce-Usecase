public without sharing class OG_DoctorSearchService {

    private static final Integer SLOT_MINS   = 30;
    private static final Integer MAX_DOCTORS = 5;
    private static final Integer MAX_SLOTS   = 10;
    private static final String  PT_SYMPTOM  = 'Onco_Symptom_To_Specialty';
    private static final String  PT_SUMMARY  = 'Onco_Doctor_Slot_Summary';

    // ── SOQL 1: Specialty list ───────────────────────────────────
    public static String buildSpecialtyList() {
        List<String> names = new List<String>();
        for (CareSpecialty cs : [SELECT Name FROM CareSpecialty
                                  WHERE IsActive = true ORDER BY Name]) {
            names.add('- ' + cs.Name);
        }
        return names.isEmpty() ? '' : String.join(names, '\n');
    }

    // ── SOQL 2: Available cities ─────────────────────────────────
    public static String buildCityList() {
        Set<String> cities = new Set<String>();
        for (HealthcareFacility f : [
            SELECT Account.BillingCity FROM HealthcareFacility
            WHERE Account.BillingCity != null
        ]) {
            cities.add(f.Account.BillingCity);
        }
        return String.join(new List<String>(cities), ', ');
    }

    // ── PT1: Symptom → Specialty ─────────────────────────────────
    public static String callSymptomPT(
            OG_FindDoctorSlotsAction.InputData inp, String specialtyList) {

        if (String.isBlank(inp.symptomDescription)) {
            return '';
        }

        try {
            ConnectApi.EinsteinPromptTemplateGenerationsInput ptIn =
                new ConnectApi.EinsteinPromptTemplateGenerationsInput();
                
            ptIn.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            ptIn.additionalConfig.applicationName = 'PromptBuilderPreview';
            ptIn.isPreview = false;
            ptIn.inputParams = new Map<String, ConnectApi.WrappedValue>();

            putParam(ptIn, 'Input:Symptom_Description', inp.symptomDescription);
            putParam(ptIn, 'Input:Specialty_List', specialtyList);

            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation resp =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(PT_SYMPTOM, ptIn);

            if (resp != null && resp.generations != null && !resp.generations.isEmpty()) {
                String result = resp.generations[0].text;
                if (String.isNotBlank(result)) {
                    if (result.contains('NO MATCH')) return '';
                    return result.trim();
                }
            }
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'PT1 failed: ' + ex.getMessage());
        }
        return '';
    }

    // ── Validate specialty ───────────────────────────────────────
    public static String validateSpecialty(String candidate, String specialtyList) {
        if (String.isBlank(candidate)) return '';

        String clean = candidate.replaceAll('["\'\\.\\,]', '').trim().toLowerCase();
        for (String line : specialtyList.split('\n')) {
            String cleanLine = line.replace('- ', '').trim();
            if (cleanLine.toLowerCase() == clean
                    || clean.contains(cleanLine.toLowerCase())) {
                return cleanLine;
            }
        }
        return '';
    }

    // ── SOQL 3: Doctor lookup ────────────────────────────────────
    public static List<ServiceResource> findDoctors(
            OG_FindDoctorSlotsAction.InputData inp, String specialty) {

        String safeCity = String.escapeSingleQuotes(inp.preferredCity.trim());

        if (String.isNotBlank(inp.doctorName)) {
            String safeName = String.escapeSingleQuotes(inp.doctorName.trim());
            return [SELECT Id, Name, RelatedRecordId
                    FROM ServiceResource WHERE IsActive = true
                    AND Name LIKE :('%' + safeName + '%')
                    AND Id IN (SELECT ServiceResourceId FROM ServiceTerritoryMember
                               WHERE ServiceTerritory.Name LIKE :('%' + safeCity + '%'))
                    LIMIT :MAX_DOCTORS];
        }

        String safeSpec = String.escapeSingleQuotes(specialty.trim());

        List<CareSpecialty> specs = [SELECT Id FROM CareSpecialty
            WHERE IsActive = true AND Name LIKE :('%' + safeSpec + '%') LIMIT 5];
        if (specs.isEmpty()) return new List<ServiceResource>();

        Set<Id> specIds = new Set<Id>();
        for (CareSpecialty cs : specs) specIds.add(cs.Id);

        List<CareProviderFacilitySpecialty> cpfsList = [
            SELECT PractitionerFacilityId FROM CareProviderFacilitySpecialty
            WHERE SpecialtyId IN :specIds AND IsActive = true
        ];
        if (cpfsList.isEmpty()) return new List<ServiceResource>();

        Set<Id> hpfIds = new Set<Id>();
        for (CareProviderFacilitySpecialty cpfs : cpfsList) {
            hpfIds.add(cpfs.PractitionerFacilityId);
        }

        List<HealthcarePractitionerFacility> hpfs = [
            SELECT PractitionerId, HealthcareFacility.Account.BillingCity
            FROM HealthcarePractitionerFacility
            WHERE Id IN :hpfIds AND IsActive = true
        ];

        Set<Id> matchedContactIds = new Set<Id>();
        for (HealthcarePractitionerFacility hpf : hpfs) {
            String city = hpf.HealthcareFacility?.Account?.BillingCity;
            if (city != null && city.equalsIgnoreCase(inp.preferredCity.trim())) {
                matchedContactIds.add(hpf.PractitionerId);
            }
        }
        if (matchedContactIds.isEmpty()) return new List<ServiceResource>();

        Map<Id, Contact> contactMap = new Map<Id, Contact>([
            SELECT Id, FirstName, LastName FROM Contact
            WHERE Id IN :matchedContactIds
        ]);

        Set<String> srNames = new Set<String>();
        for (Contact doc : contactMap.values()) {
            srNames.add('SR_' + doc.FirstName + '_' + doc.LastName);
        }
        if (srNames.isEmpty()) return new List<ServiceResource>();

        return [SELECT Id, Name, RelatedRecordId FROM ServiceResource
                WHERE IsActive = true AND Name IN :srNames
                LIMIT :MAX_DOCTORS];
    }

    // ── SOQL 4: Operating hours + time slots ─────────────────────
    public static Map<Id, List<TimeSlot>> fetchTimeSlots(List<ServiceResource> resources) {
        Map<Id, Id> resOhMap = new Map<Id, Id>();
        Set<Id> ohIds = new Set<Id>();

        for (ServiceTerritoryMember m : [
                SELECT ServiceResourceId, OperatingHoursId
                FROM ServiceTerritoryMember
                WHERE ServiceResourceId IN :resources]) {
            resOhMap.put(m.ServiceResourceId, m.OperatingHoursId);
            ohIds.add(m.OperatingHoursId);
        }

        Map<Id, List<TimeSlot>> ohTsMap = new Map<Id, List<TimeSlot>>();
        for (TimeSlot ts : [SELECT OperatingHoursId, DayOfWeek, StartTime, EndTime
                             FROM TimeSlot WHERE OperatingHoursId IN :ohIds
                             AND Type = 'Normal' ORDER BY DayOfWeek, StartTime]) {
            if (!ohTsMap.containsKey(ts.OperatingHoursId)) {
                ohTsMap.put(ts.OperatingHoursId, new List<TimeSlot>());
            }
            ohTsMap.get(ts.OperatingHoursId).add(ts);
        }

        Map<Id, List<TimeSlot>> result = new Map<Id, List<TimeSlot>>();
        for (Id rid : resOhMap.keySet()) {
            Id ohId = resOhMap.get(rid);
            result.put(rid, ohTsMap.containsKey(ohId)
                ? ohTsMap.get(ohId) : new List<TimeSlot>());
        }
        return result;
    }

    // ── Build raw data for PT2 ───────────────────────────────────
    public static String buildRawData(
            List<ServiceResource> resources,
            Map<Id, List<TimeSlot>> slotsMap,
            Map<String, List<ServiceAppointment>> bookedMap,
            Date targetDate, String city) {

        Map<Id, ServiceTerritoryMember> terrMap = new Map<Id, ServiceTerritoryMember>();
        for (ServiceTerritoryMember m : [
                SELECT ServiceResourceId, ServiceTerritoryId, ServiceTerritory.Name
                FROM ServiceTerritoryMember WHERE ServiceResourceId IN :resources]) {
            terrMap.put(m.ServiceResourceId, m);
        }

        DateTime now = DateTime.now();
        String dayName = DateTime.newInstance(
            targetDate, Time.newInstance(12,0,0,0)).format('EEEE');
        List<String> lines = new List<String>();
        Integer total = 0;

        lines.add('SEARCH_DATE: ' + targetDate.format());
        lines.add('SEARCH_CITY: ' + city);
        lines.add('DOCTORS_FOUND: ' + resources.size());
        lines.add('');

        for (ServiceResource sr : resources) {
            ServiceTerritoryMember stm = terrMap.get(sr.Id);
            String terrName = stm != null ? stm.ServiceTerritory.Name : city;
            String terrId = stm != null ? stm.ServiceTerritoryId : '';

            lines.add('DOCTOR_NAME: ' + sr.Name);
            lines.add('RESOURCE_ID: ' + sr.Id);
            lines.add('HOSPITAL: ' + terrName);
            lines.add('TERRITORY_ID: ' + terrId);

            List<TimeSlot> timeSlots = slotsMap.get(sr.Id);
            if (timeSlots == null || timeSlots.isEmpty()) {
                lines.add('AVAILABLE_SLOTS: none (hours not configured)');
                lines.add('');
                continue;
            }

            Map<String, List<TimeSlot>> dayMap = new Map<String, List<TimeSlot>>();
            for (TimeSlot ts : timeSlots) {
                if (!dayMap.containsKey(ts.DayOfWeek)) dayMap.put(ts.DayOfWeek, new List<TimeSlot>());
                dayMap.get(ts.DayOfWeek).add(ts);
            }

            List<TimeSlot> daySlots = dayMap.get(dayName);
            if (daySlots == null || daySlots.isEmpty()) {
                lines.add('AVAILABLE_SLOTS: none (not available on ' + dayName + 's)');
                lines.add('');
                continue;
            }

            String dateKey = sr.Id + '_'
                + DateTime.newInstance(targetDate, Time.newInstance(0,0,0,0))
                          .format('yyyy-MM-dd');
            List<ServiceAppointment> dayBooked = bookedMap.get(dateKey);

            List<String> free = new List<String>();
            for (TimeSlot daySlot : daySlots) {
                DateTime slotStart = DateTime.newInstance(targetDate, daySlot.StartTime);
                DateTime slotEnd = DateTime.newInstance(targetDate, daySlot.EndTime);

                while (slotStart.addMinutes(SLOT_MINS) <= slotEnd && free.size() < MAX_SLOTS) {
                    DateTime sEnd = slotStart.addMinutes(SLOT_MINS);
                    if (targetDate == Date.today() && slotStart < now) {
                        slotStart = sEnd;
                        continue;
                    }
                    if (!isBooked(slotStart, sEnd, dayBooked)) {
                        free.add(slotStart.format('h:mm a') + '-' + sEnd.format('h:mm a'));
                        total++;
                    }
                    slotStart = sEnd;
                }
            }

            lines.add(free.isEmpty()
                ? 'AVAILABLE_SLOTS: none (fully booked)'
                : 'AVAILABLE_SLOTS: ' + String.join(free, ', '));
            lines.add('');
        }
        lines.add('TOTAL_AVAILABLE_SLOTS: ' + total);
        return String.join(lines, '\n');
    }

    public static Map<String, List<ServiceAppointment>> fetchBooked(List<ServiceResource> resources, Date startDate) {
        Map<String, List<ServiceAppointment>> m = new Map<String, List<ServiceAppointment>>();
        
        DateTime dayStart = DateTime.newInstance(startDate, Time.newInstance(0,0,0,0));
        DateTime dayEnd = DateTime.newInstance(startDate.addDays(7), Time.newInstance(23,59,59,0));

        for (AssignedResource ar : [SELECT ServiceResourceId, 
                                           ServiceAppointment.SchedStartTime, 
                                           ServiceAppointment.SchedEndTime 
                                    FROM AssignedResource 
                                    WHERE ServiceResourceId IN :resources 
                                    AND ServiceAppointment.SchedStartTime >= :dayStart 
                                    AND ServiceAppointment.SchedStartTime <= :dayEnd 
                                    AND ServiceAppointment.Status NOT IN ('Canceled', 'Cannot Complete')]) {
            
            String dateKey = ar.ServiceResourceId + '_' + ar.ServiceAppointment.SchedStartTime.format('yyyy-MM-dd');
            if (!m.containsKey(dateKey)) m.put(dateKey, new List<ServiceAppointment>());
            m.get(dateKey).add(ar.ServiceAppointment);
        }
        return m;
    }

    public static List<OG_FindDoctorSlotsAction.DoctorInfo> buildDoctorList(
            List<ServiceResource> resources, Map<Id, List<TimeSlot>> slotsMap, Date startDate, String city) {
        
        List<OG_FindDoctorSlotsAction.DoctorInfo> docs = new List<OG_FindDoctorSlotsAction.DoctorInfo>();
        DateTime now = DateTime.now();
        
        Set<Id> resIds = new Set<Id>();
        for (ServiceResource sr : resources) resIds.add(sr.Id);
        
        Map<String, List<ServiceAppointment>> bookedMap = fetchBooked(resources, startDate);
        
        List<ServiceTerritoryMember> members = [SELECT ServiceResourceId, ServiceResource.Name, ServiceTerritory.Name, ServiceTerritoryId 
                                                FROM ServiceTerritoryMember 
                                                WHERE ServiceResourceId IN :resIds 
                                                AND (EffectiveStartDate <= :startDate OR EffectiveStartDate = null)
                                                LIMIT 10];

        for (ServiceTerritoryMember stm : members) {
            OG_FindDoctorSlotsAction.DoctorInfo di = new OG_FindDoctorSlotsAction.DoctorInfo();
            di.name = stm.ServiceResource.Name;
            di.resourceId = stm.ServiceResourceId;
            di.hospitalName = stm.ServiceTerritory.Name;
            
            Map<String, List<String>> dateSlots = new Map<String, List<String>>();
            List<TimeSlot> timeSlots = slotsMap.get(stm.ServiceResourceId);
            
            if (timeSlots != null && !timeSlots.isEmpty()) {
                Map<String, List<TimeSlot>> dayMap = new Map<String, List<TimeSlot>>();
                for (TimeSlot ts : timeSlots) {
                    if (!dayMap.containsKey(ts.DayOfWeek)) dayMap.put(ts.DayOfWeek, new List<TimeSlot>());
                    dayMap.get(ts.DayOfWeek).add(ts);
                }

                for (Integer i = 0; i < 7; i++) {
                    Date targetDate = startDate.addDays(i);
                    String dayName = DateTime.newInstance(targetDate, Time.newInstance(0,0,0,0)).format('EEEE');
                    String dateStr = DateTime.newInstance(targetDate, Time.newInstance(0,0,0,0)).format('yyyy-MM-dd');
                    
                    List<TimeSlot> daySlots = dayMap.get(dayName);
                    if (daySlots == null || daySlots.isEmpty()) continue;

                    String dateKey = stm.ServiceResourceId + '_' + dateStr;
                    List<ServiceAppointment> dayBooked = bookedMap.get(dateKey);
                    List<String> free = new List<String>();

                    for (TimeSlot daySlot : daySlots) {
                        DateTime slotStart = DateTime.newInstance(targetDate, daySlot.StartTime);
                        DateTime slotEnd = DateTime.newInstance(targetDate, daySlot.EndTime);

                        while (slotStart.addMinutes(SLOT_MINS) <= slotEnd && free.size() < MAX_SLOTS) {
                            DateTime sEnd = slotStart.addMinutes(SLOT_MINS);
                            if (targetDate == Date.today() && slotStart < now) {
                                slotStart = sEnd;
                                continue;
                            }
                            if (!isBooked(slotStart, sEnd, dayBooked)) {
                                free.add(slotStart.format('h:mm a'));
                            }
                            slotStart = sEnd;
                        }
                    }
                    if (!free.isEmpty()) dateSlots.put(dateStr, free);
                }
            }
            di.slotsJson = JSON.serialize(dateSlots);
            docs.add(di);
        }
        return docs;
    }

    public static Boolean isBooked(DateTime s, DateTime e,
            List<ServiceAppointment> booked) {
        if (booked == null || booked.isEmpty()) return false;
        for (ServiceAppointment b : booked) {
            if (s < b.SchedEndTime && e > b.SchedStartTime) return true;
        }
        return false;
    }

    // ── PT2: Format for patient ──────────────────────────────────
    public static String callSummaryPT(
            String rawData, String specialty, String city,
            String dateStr, String contextData) {
        try {
            ConnectApi.EinsteinPromptTemplateGenerationsInput ptIn =
                new ConnectApi.EinsteinPromptTemplateGenerationsInput();
                
            ptIn.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            ptIn.additionalConfig.applicationName = 'PromptBuilderPreview';
            ptIn.isPreview = false;
            ptIn.inputParams = new Map<String, ConnectApi.WrappedValue>();

            putParam(ptIn, 'Input:rawDoctorData', rawData);
            putParam(ptIn, 'Input:specialtyName', specialty);
            putParam(ptIn, 'Input:preferredCity', city);
            putParam(ptIn, 'Input:preferredDate',
                String.isNotBlank(dateStr) ? dateStr : 'today');
            putParam(ptIn, 'Input:contextData', contextData);

            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation resp =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(PT_SUMMARY, ptIn);

            if (resp?.generations != null && !resp.generations.isEmpty()
                    && String.isNotBlank(resp.generations[0].text)) {
                return resp.generations[0].text.trim();
            }
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'PT2 failed: ' + ex.getMessage());
        }
        return buildHumanReadableFallback(rawData, specialty, city);
    }

    private static String buildHumanReadableFallback(
            String rawData, String specialty, String city) {
        List<String> result = new List<String>();
        result.add('Here are the available ' + specialty + ' doctors in ' + city + ':\n');
        String currentDoctor = '';
        for (String line : rawData.split('\n')) {
            line = line.trim();
            if (line.startsWith('DOCTOR_NAME: ')) {
                currentDoctor = line.replace('DOCTOR_NAME: ', '').replace('SR_', 'Dr. ').replace('_', ' ');
            } else if (line.startsWith('AVAILABLE_SLOTS: ')) {
                String slots = line.replace('AVAILABLE_SLOTS: ', '');
                result.add('Doctor: ' + currentDoctor);
                result.add('Available Slots: ' + (slots.startsWith('none') ? 'Not available' : slots));
                result.add('');
            }
        }
        return String.join(result, '\n');
    }

    private static void putParam(
            ConnectApi.EinsteinPromptTemplateGenerationsInput ptIn,
            String key, String value) {
        ConnectApi.WrappedValue wv = new ConnectApi.WrappedValue();
        wv.value = value;
        ptIn.inputParams.put(key, wv);
    }

    public static Date parseDate(String s) {
        if (String.isNotBlank(s)) {
            try { return Date.valueOf(s.trim()); }
            catch (Exception ex) {}
        }
        return Date.today();
    }

    public static String buildAlternatives(
            String specialty, String requestedCity, String allCities) {
        return 'Try a different city or date? Available cities: ' + allCities;
    }
}