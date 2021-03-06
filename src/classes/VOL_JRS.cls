/*******************************************************************************************************
* @author David Habib
* @date 11/1/2012
* @description Main class for managing Volunteer Job Recurrence Schedules (JRS). 
*
* Written by Dave Habib, copyright (c) 2012 Groundwire
* This program is released under the GNU Affero General Public License, Version 3. http://www.gnu.org/licenses/
********************************************************************************************************/
public with sharing class VOL_JRS {

    //******************************************************************************************************
	// for the specified JRS's, delete all shifts that have no committed & completed hours.
	// called from the Before Delete JRS trigger.
	public static void DeleteListJRS(list<Job_Recurrence_Schedule__c> listJRS) {
		
		// get a set of the JRS ID's for querying
		set<ID> setJRSId = new set<ID>();
		for (Job_Recurrence_Schedule__c jrs : listJRS) {
			setJRSId.add(jrs.Id);
		}
		
		// get all shifts associated with these JRS's that we should delete
		list<Volunteer_Shift__c> listShift = new list<Volunteer_Shift__c>();
		listShift = [select Id, Total_Volunteers__c from Volunteer_Shift__c  
			where ((Total_Volunteers__c = null or Total_Volunteers__c = 0) and 
				Job_Recurrence_Schedule__c in : setJRSId)];
		
		delete listShift;
	}

    //******************************************************************************************************
	// given a list of recurring schedules, does all the work to delete any shifts that
	// no longer match, and creates new shifts into the future.
	// called from both the JRS trigger (when the user modifies a specific JRS),
	// as well as from the batch process to reprocess all JRS's.
	// fReviewAllShifts parameter specifies whether called from the trigger on JRS's, in
	// which case we should review all shifts under the JRS, or from the scheduled batch,
	// in which case we only need to be looking to add additional shifts in the future.
	public static void ProcessListJRS(list<Job_Recurrence_Schedule__c> listJRS, boolean fReviewAllShifts) {
		
		// get a set of the JRS ID's for querying
		set<ID> setJRSId = new set<ID>();
		for (Job_Recurrence_Schedule__c jrs : listJRS) {
			setJRSId.add(jrs.Id);
		}
		
		// get all shifts associated with these JRS's
		list<Volunteer_Shift__c> listShift = new list<Volunteer_Shift__c>();
		listShift = [select Id, Start_Date_Time__c, Job_Recurrence_Schedule__c, 
				Total_Volunteers__c, Desired_Number_of_Volunteers__c, Volunteer_Job__c, Description__c, System_Note__c
			from Volunteer_Shift__c where Job_Recurrence_Schedule__c in : setJRSId 
			order by Start_Date_Time__c];
			
		// construct a map of JRS to its associated shifts
		map<ID, list<Volunteer_Shift__c>> mapJRSIdShift = new map<ID, list<Volunteer_Shift__c>>();
		
		// put the Shifts on each JRS's list
		for (Volunteer_Shift__c shift : listShift) {			
			list<Volunteer_Shift__c> listJRSShift = mapJRSIdShift.get(shift.Job_Recurrence_Schedule__c);
			if (listJRSShift == null) listJRSShift = new list<Volunteer_Shift__c>();
			listJRSShift.add(shift);
			mapJRSIdShift.put(shift.Job_Recurrence_Schedule__c, listJRSShift);				
		}

		// lists to hold all the shifts we need to create, delete, and update
		list<Volunteer_Shift__c> listShiftNew = new list<Volunteer_Shift__c>();
		list<Volunteer_Shift__c> listShiftDelete = new list<Volunteer_Shift__c>();
		list<Volunteer_Shift__c> listShiftUpdate = new list<Volunteer_Shift__c>();
		
		// now look at each JRS's shifts, and decide what to do, potentially adding more shifts
		for (Job_Recurrence_Schedule__c jrs : listJRS) {
			list<Volunteer_Shift__c> listJRSShift = mapJRSIdShift.get(jrs.Id);
			if (listJRSShift == null) listJRSShift = new list<Volunteer_Shift__c>(); 
			ProcessJRS(jrs, listJRSShift, listShiftNew, listShiftDelete, listShiftUpdate, fReviewAllShifts);
		}
		
		// commit the work
		if (listShiftNew.size() > 0)
			insert listShiftNew;
		if (listShiftDelete.size() > 0)
			delete listShiftDelete;		
		if (listShiftUpdate.size() > 0)
			update listShiftUpdate;

		// get all Volunteer Recurring Schedules associated with these shift's jobs.
		set<ID> setJobId = new set<ID>();
		for (Volunteer_Shift__c shift : listShiftNew) {
			setJobId.add(shift.Volunteer_Job__c);
		}
		list<Volunteer_Recurrence_Schedule__c> listVRS = new list<Volunteer_Recurrence_Schedule__c>();
		listVRS = [select Id, Name, Contact__c, Schedule_Start_Date_Time__c, Schedule_End_Date__c, Duration__c,
			Weekly_Occurrence__c, Days_Of_Week__c, Volunteer_Job__c, Volunteer_Hours_Status__c
			from Volunteer_Recurrence_Schedule__c where Volunteer_Job__c in : setJobId];
			
		// process the VRS's to create hours as needed.
		VOL_VRS.ProcessListVRS(listVRS);
	}

    //******************************************************************************************************
	// Process a single recurrence schedule, adding new shifts to the passed in list.
	// fReviewAllShifts specifies whether we should verify old shifts still match the schedule.
	private static void ProcessJRS(Job_Recurrence_Schedule__c jrs, 
		list<Volunteer_Shift__c> listJRSShift, // assumes ordered by ascending date
		list<Volunteer_Shift__c> listShiftNew, 
		list<Volunteer_Shift__c> listShiftDelete,
		list<Volunteer_Shift__c> listShiftUpdate,
		boolean fReviewAllShifts ) {
	
		// assume custom setting to specify how far into future shifts should populate to.
		Date dtStop = system.today();
		integer nMonths = 12;
		if (VOL_SharedCode.VolunteersSettings.Recurring_Job_Future_Months__c != null) {
			nMonths = integer.valueOf(VOL_SharedCode.VolunteersSettings.Recurring_Job_Future_Months__c); 
		}
		dtStop = dtStop.addMonths(nMonths);
		
		if (jrs.Schedule_End_Date__c != null)
			dtStop = jrs.Schedule_End_Date__c;
		
		// create a map of date to shift, for quick lookups.
		map<Date, Volunteer_Shift__c> mapDtShift = new map<Date, Volunteer_Shift__c>();
		for (Volunteer_Shift__c shift: listJRSShift) {
			mapDtShift.put(shift.Start_Date_Time__c.date(), shift);
		}
		
		// if fReviewAllShifts, we'll start at the JRS's start date.
		// if !fReviewAllShifts, we'll just start after the latest shift (if we have one).
		Date dtLast;
		if (fReviewAllShifts) {
			dtLast = jrs.Schedule_Start_Date_Time__c.date().addDays(-1);  // -1, so we'll create on start date if appropriate.
		} else if (listJRSShift.size() > 0) {
			dtLast = date.valueOf(listJRSShift[listJRSShift.size() - 1].Start_Date_Time__c);
		} else {
			dtLast = system.Today();			
		}
		
		while (dtLast < dtStop) {
			dtLast = dtNextDateForJRS(jrs, dtLast);
			
			if (dtLast == null || dtLast > dtStop) 
				break;
			
			// see if we already have a shift for that date
			Volunteer_Shift__c shiftExisting = mapDtShift.get(dtLast);
			
			// if we have the shift, update its Job, time and duration
			if (shiftExisting != null) {
				shiftExisting.Duration__c = jrs.Duration__c;
				shiftExisting.Start_Date_Time__c = datetime.newInstance(dtLast, jrs.Schedule_Start_Date_Time__c.time());
				if (jrs.Desired_Number_of_Volunteers__c != null)
					shiftExisting.Desired_Number_of_Volunteers__c = jrs.Desired_Number_of_Volunteers__c;
				if (jrs.Description__c != null)
					shiftExisting.Description__c = jrs.Description__c;
				listShiftUpdate.add(shiftExisting);	
				// also remove the shift from our map, so we'll end up with those to delete.
				mapDtShift.remove(dtLast);			
			} else {
				Volunteer_Shift__c shift = new Volunteer_Shift__c();
				shift.System_Note__c = label.labelJRSShiftCreatedSystemNote + ' ' + jrs.Name + '.';
				shift.Description__c = jrs.Description__c;
				shift.Job_Recurrence_Schedule__c = jrs.Id;
				shift.Duration__c = jrs.Duration__c;
				shift.Volunteer_Job__c = jrs.Volunteer_Job__c;				
				shift.Start_Date_Time__c = datetime.newInstance(dtLast, jrs.Schedule_Start_Date_Time__c.time());
				shift.Desired_Number_of_Volunteers__c = jrs.Desired_Number_of_Volunteers__c;
				listShiftNew.add(shift);
			}
		}
		
		// we've finished identifying shifts to update and those to create.
		// now figure out if there are any to delete or remove from the jrs.
		if (fReviewAllShifts) {
			for (Volunteer_Shift__c shift: mapDtShift.values()) {
				if (shift.Total_Volunteers__c > 0) {
					shift.Job_Recurrence_Schedule__c = null;
					shift.System_Note__c += ' ' + label.labelJRSShiftRemovedSystemNote + ' ' + jrs.Name + '.';					
					listShiftUpdate.add(shift);	
				} else {
					listShiftDelete.add(shift);
				}
			}			
		}		
		
		// we don't commit the shifts, leaving the caller to do it.		
	}
	
    //******************************************************************************************************
	// return the next scheduled date for the given schedule, from the passed in date (exclusive).
	// DOES NOT assume the passed in date is valid for the schedule.
	private static Date dtNextDateforJRS(Job_Recurrence_Schedule__c jrs, Date dt) {
		
		// strategy is to find the first valid nday, and then find its next nweek.
		Date dtFirst = dtFirstOccurrenceInWeek(jrs, dt);
		boolean fAlternate = true;	// we assume the first date passed in is a valid week.
		boolean fValidWeek = validWeek(jrs, dtFirst, fAlternate);  // remember if current date is on valid week.
		
		// if we aren't on a valid week we want to skip to the first nday of the next week.		
		if (!fValidWeek) {
			dt = dtFirst.addDays(6);
		}
		
		integer nDay = nDayOfWeek(dt);
		list<boolean> listWhichDays = WhichDaysJRS(jrs);
		
		for (integer n = nDay; true; ) {
			n++;
			dt = dt.addDays(1);
			
			if (n == 8) {
				n = 1;
				fAlternate = !fAlternate;
			}
			
			if (!listWhichDays[n]) {
				continue;
			}
			
			// we've found the next day.
			// now find the correct week.
			if ((fValidWeek && n > nDay) || validWeek(jrs, dt, fAlternate)) {
				break;
			}
			integer cweeks = cWeeksNext(jrs, dt, fAlternate);
			dt = dt.addDays(cweeks * 7);
			break;			
		}
		
		return dt;		
	}
	
    //******************************************************************************************************
	// returns an array of booleans for which days are on the schedule.
	// note that you should index by nDay (ie, Mon = index 2).
	private static list<boolean> WhichDaysJRS (Job_Recurrence_Schedule__c jrs) {
		list<boolean> listWhichDays = new boolean[] { false, false, false, false, false, false, false, false };
		if (jrs.Days_of_Week__c != null) {
			listWhichDays[1] = jrs.Days_of_Week__c.contains('Sunday');
			listWhichDays[2] = jrs.Days_of_Week__c.contains('Monday');
			listWhichDays[3] = jrs.Days_of_Week__c.contains('Tuesday');
			listWhichDays[4] = jrs.Days_of_Week__c.contains('Wednesday');
			listWhichDays[5] = jrs.Days_of_Week__c.contains('Thursday');
			listWhichDays[6] = jrs.Days_of_Week__c.contains('Friday');
			listWhichDays[7] = jrs.Days_of_Week__c.contains('Saturday');
		}
		return listWhichDays; 
	}

    //******************************************************************************************************
	// returns an array of booleans for which weeks are on the schedule.
	// note that you should index by nWeek (ie, first = index 1).
	private static list<boolean> WhichWeeksJRS(Job_Recurrence_Schedule__c jrs) { 
		list<boolean> listWhichWeeks = new boolean[] { false, false, false, false, false, false };
		if (jrs.Weekly_Occurrence__c != null) {
			listWhichWeeks[1] = jrs.Weekly_Occurrence__c.contains('1st');
			listWhichWeeks[2] = jrs.Weekly_Occurrence__c.contains('2nd');
			listWhichWeeks[3] = jrs.Weekly_Occurrence__c.contains('3rd');
			listWhichWeeks[4] = jrs.Weekly_Occurrence__c.contains('4th');
			listWhichWeeks[5] = jrs.Weekly_Occurrence__c.contains('5th');
		}
		return listWhichWeeks;
	}   


    //******************************************************************************************************
	// given the current date, return the first date in that week that should be scheduled		
	private static Date dtFirstOccurrenceInWeek(Job_Recurrence_Schedule__c jrs, Date dt) {
		list<boolean> listWhichDays = WhichDaysJRS(jrs);
		integer nday = nDayOfWeek(dt);
		integer n;
		for (n = 1; n < nday; n++) {
			if (listWhichDays[n])
				break;
		}		
		return dt.addDays(n - nday);
	} 	
		
    //******************************************************************************************************
	// return the occurrence of the day in the month (ie, 1 first - 5 fifth)
	public static integer nWeekOfDate(Date dt) {
		return ((dt.day() - 1) / 7) + 1;
	}
	
    //******************************************************************************************************
	// return the date of the nth day in the nth week of the provided month and year
	// ie, return the 2nd Friday of Feb 2012.  
	// nday: 1 - 7 (implying Sun - Sat)
	// nweek: 1 - 5 (implying first - fifth)
	public static Date dtNthDay(integer year, integer month, integer nday, integer nweek) {
		Date dtStartMonth = date.NewInstance(year, month, 1);
		integer ndayStartMonth = nDayOfWeek(dtStartMonth);
		integer day;
		if (nday >= ndayStartMonth) {
			day = nday - ndayStartMonth + 1 + ((nweek-1) * 7);
		} else {
			day = (nweek * 7) - (ndayStartMonth - nday - 1);			
		}
		return Date.NewInstance(year, month, day);		
	} 
	
    //******************************************************************************************************
	// returns an integer 1 - 7, represening the day of the week.
	public static integer nDayOfWeek(Date dt) {
		return (dt.toStartOfWeek().daysBetween(dt) + 1);		
	}
	
    //******************************************************************************************************
	// returns whether the nweek of the specified date is valid for this schedule
	private static boolean validWeek(Job_Recurrence_Schedule__c jrs, Date dt, boolean fAlternate) {
		integer nweek = nWeekOfDate(dt);
		list<boolean> listWhichWeeks = WhichWeeksJRS(jrs);
		if (jrs.Weekly_Occurrence__c == null)
			return false;
		else if (listWhichWeeks[nweek] || jrs.Weekly_Occurrence__c.contains('Every'))
			return true;
		else if (fAlternate && jrs.Weekly_Occurrence__c.contains('Alternate'))
			return true;
		else
			return false;
	}	
	
    //******************************************************************************************************
	// returns how many weeks until the next recurrence on the schedule
	private static integer cWeeksNext(Job_Recurrence_Schedule__c jrs, Date dt, boolean fAlternate) {
		if (jrs.Weekly_Occurrence__c == null) {
			// treat empty as every week, so we avoid infinite loops.
			return 1;
		} else if (jrs.Weekly_Occurrence__c.contains('Every')) { 
			return 1;
		} else if (jrs.Weekly_Occurrence__c.contains('Alternate')) {
			return fAlternate ? 2 : 1;
		} else {
			list<boolean> listWhichWeeks = WhichWeeksJRS(jrs);
			integer nweek = nWeekOfDate(dt);
			integer cweeks = 0;
			
			for (integer n = nweek + 1; true; n++) {
				if (n == 6) {
					Date dtEndOfMonth = dt.toStartOfMonth().addMonths(1).addDays(-1);
					cweeks = (dt.daysBetween(dtEndOfMonth) / 7) + 1;
					nweek = 1;
					n = 0;
					continue;
				}
				if (listWhichWeeks[n]) { 
					return (n - nweek + cweeks);
				}
			}
		}
		return 0;
	}  
	 


    //******************************************************************************************************
    // TEST METHODS

    //******************************************************************************************************
    // Test Job Recurrence Schedules    
    public static testmethod void TestJRS() {

		// create test data
        Campaign cmp = new Campaign(recordtypeid=VOL_SharedCode.recordtypeIdVolunteersCampaign, 
        	name='Job Calendar Test Campaign', IsActive=true);
        insert cmp;
        Volunteer_Job__c job = new Volunteer_Job__c(name='Job1', campaign__c=cmp.Id);
        insert job;
        Volunteer_Shift__c shift = new Volunteer_Shift__c(Volunteer_Job__c=job.Id, Duration__c=1, 
        	Start_Date_Time__c=date.valueOf('2012-1-1')	);  // 1/1/2012 was a Sunday
        insert shift;
        Job_Recurrence_Schedule__c jrs = new Job_Recurrence_Schedule__c(Volunteer_Job__c = job.Id);
		jrs.Days_of_Week__c = 'Monday;Wednesday;Friday';
		jrs.Duration__c = 1;
		jrs.Schedule_Start_Date_Time__c = datetime.parse('1/1/2012 10:00 AM');
		jrs.Weekly_Occurrence__c = 'Every';
		jrs.Desired_Number_of_Volunteers__c = 5;
		insert jrs;
		
		// test Day of Week
		system.assertEquals(1, nDayOfWeek(date.valueOf('2012-1-1')));
		system.assertEquals(7, nDayOfWeek(date.valueOf('2012-1-7')));
		system.assertEquals(3, nDayOfWeek(date.valueOf('2012-1-31')));
		system.assertEquals(4, nDayOfWeek(date.valueOf('2012-2-1')));
		system.assertEquals(4, nDayOfWeek(date.valueOf('2012-2-29')));
		
		// test dtNthDay
		system.assertEquals(date.valueOf('2012-1-1'), dtNthDay(2012, 1, 1, 1));
		system.assertEquals(date.valueOf('2012-1-7'), dtNthDay(2012, 1, 7, 1));
		system.assertEquals(date.valueOf('2012-1-8'), dtNthDay(2012, 1, 1, 2));
		system.assertEquals(date.valueOf('2012-1-31'), dtNthDay(2012, 1, 3, 5));
		system.assertEquals(date.valueOf('2012-2-3'), dtNthDay(2012, 2, 6, 1));		
		system.assertEquals(date.valueOf('2012-2-6'), dtNthDay(2012, 2, 2, 1));
		system.assertEquals(date.valueOf('2012-2-27'), dtNthDay(2012, 2, 2, 4));
		system.assertEquals(date.valueOf('2012-2-29'), dtNthDay(2012, 2, 4, 5));
		system.assertEquals(date.valueOf('2012-2-18'), dtNthDay(2012, 2, 7, 3));
		
		// test Every week.
		Date dtNext =  dtNextDateforJRS(jrs, date.valueOf(shift.Start_Date_Time__c));
		system.assertEquals(1, cWeeksNext(jrs, dtNext, false));		
		system.assertEquals(date.valueOf('2012-1-2'), dtNext); 	
		dtNext =  dtNextDateforJRS(jrs, dtNext);
		system.assertEquals(date.valueOf('2012-1-4'), dtNext); 	
		dtNext =  dtNextDateforJRS(jrs, dtNext);
		system.assertEquals(date.valueOf('2012-1-6'), dtNext); 	
		dtNext =  dtNextDateforJRS(jrs, dtNext);
		system.assertEquals(date.valueOf('2012-1-9'), dtNext); 	
		
		// test Alternate weeks.
		jrs.Weekly_Occurrence__c = 'Alternate';
		update jrs;
		system.assertEquals(2, cWeeksNext(jrs, dtNext, true));		
		dtNext =  dtNextDateforJRS(jrs, dtNext);
		system.assertEquals(date.valueOf('2012-1-11'), dtNext); 	
		dtNext =  dtNextDateforJRS(jrs, dtNext);
		system.assertEquals(date.valueOf('2012-1-13'), dtNext); 	
		dtNext =  dtNextDateforJRS(jrs, dtNext);
		system.assertEquals(date.valueOf('2012-1-23'), dtNext); 
		
		// test figuring out occurrence of day in month
		system.assertEquals(1, nWeekOfDate(date.valueOf('2012-1-1')));
		system.assertEquals(1, nWeekOfDate(date.valueOf('2012-1-7')));
		system.assertEquals(2, nWeekOfDate(date.valueOf('2012-1-8')));
		system.assertEquals(5, nWeekOfDate(date.valueOf('2012-1-29')));
		system.assertEquals(5, nWeekOfDate(date.valueOf('2012-1-31')));
		system.assertEquals(1, nWeekOfDate(date.valueOf('2012-2-1')));
		system.assertEquals(1, nWeekOfDate(date.valueOf('2012-2-4')));
		system.assertEquals(1, nWeekOfDate(date.valueOf('2012-2-5')));
		system.assertEquals(5, nWeekOfDate(date.valueOf('2012-2-29')));
		system.assertEquals(1, nWeekOfDate(date.valueOf('2012-2-6')));
		
		// test Nth week of Month
		jrs.Weekly_Occurrence__c = '3rd';
		update jrs;
		list<boolean> listWhichWeeks = WhichWeeksJRS(jrs);
		system.assertEquals(false, listWhichWeeks[0]);
		system.assertEquals(false, listWhichWeeks[1]);
		system.assertEquals(false, listWhichWeeks[2]);
		system.assertEquals(true, listWhichWeeks[3]);
		system.assertEquals(false, listWhichWeeks[4]);
		system.assertEquals(false, listWhichWeeks[5]);

		system.assertEquals(2, cWeeksNext(jrs, date.valueOf('2012-1-1'), false));		
		system.assertEquals(2, cWeeksNext(jrs, date.valueOf('2012-1-7'), false));		
		system.assertEquals(1, cWeeksNext(jrs, date.valueOf('2012-1-8'), false));		
		system.assertEquals(1, cWeeksNext(jrs, date.valueOf('2012-1-14'), false));		
		system.assertEquals(5, cWeeksNext(jrs, date.valueOf('2012-1-15'), false));		

		dtNext =  dtNextDateforJRS(jrs, date.valueOf('2012-1-7')); 
		system.assertEquals(date.valueOf('2012-1-16'), dtNext); 

		jrs.Days_of_Week__c = 'Monday';
		update jrs;
		dtNext =  dtNextDateforJRS(jrs, date.valueOf('2012-4-16'));
		system.assertEquals(date.valueOf('2012-5-21'), dtNext); 

		jrs.Days_of_Week__c = 'Wednesday';
		update jrs;
		dtNext =  dtNextDateforJRS(jrs, date.valueOf('2012-4-18'));
		system.assertEquals(date.valueOf('2012-5-16'), dtNext); 

		jrs.Weekly_Occurrence__c = '1st';
		jrs.Days_of_Week__c = 'Monday';
		update jrs;
		dtNext =  dtNextDateforJRS(jrs, date.valueOf('2012-2-6'));
		system.assertEquals(date.valueOf('2012-3-5'), dtNext); 
		
		jrs.Weekly_Occurrence__c = '2nd;4th;';
		jrs.Days_of_Week__c = 'Sunday';
		update jrs;
		dtNext =  dtNextDateforJRS(jrs, date.valueOf('2012-8-1'));
		system.assertEquals(date.valueOf('2012-8-12'), dtNext);  
		
		// test batch calculations
       	VOL_BATCH_Recurrence r = new VOL_BATCH_Recurrence();
    	r.execute(null);	
		
		// test deleting the JRS
		list<Volunteer_Shift__c> listShift = [select Id, Name from Volunteer_Shift__c where Job_Recurrence_Schedule__c = :jrs.Id];
		system.assert(listShift.size() > 0);
		delete jrs;
		listShift = [select Id, Name from Volunteer_Shift__c where Job_Recurrence_Schedule__c = :jrs.Id];
		system.assertEquals(0, listShift.size());
		
    }   


}