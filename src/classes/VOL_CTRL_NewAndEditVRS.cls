/*******************************************************************************************************
* @author David Habib
* @date 12/1/2012
* @description controller class for the New and Update Volunteer Recurrence Schedules visualforce page. 
*
* Written by Dave Habib, copyright (c) 2012 Groundwire
* This program is released under the GNU Affero General Public License, Version 3. http://www.gnu.org/licenses/
********************************************************************************************************/
public with sharing class VOL_CTRL_NewAndEditVRS {

	public Volunteer_Recurrence_Schedule__c vrs { get; set; }
	public ID jrsId { get; set; }

	//constructor
	public VOL_CTRL_NewAndEditVRS (ApexPages.StandardController controller) {

		//get record from standard controller
        vrs = (Volunteer_Recurrence_Schedule__c)controller.getRecord();	
	}
	
    // the list of Job Recurrence Schedules for the current job
    public list<SelectOption> listSOJRS {
    	get {
    		if (listSOJRS == null) {
		        list<SelectOption> listSO = new list<SelectOption>();
		        listSO.add(new SelectOption('', ''));
		        ID jobId = vrs.Volunteer_Job__c;
		        
		        for (Job_Recurrence_Schedule__c jrs : [select Id, Name, Days_of_Week__c, Duration__c, 
		        	Schedule_Start_Date_Time__c, Schedule_End_Date__c, Weekly_Occurrence__c from Job_Recurrence_Schedule__c 
		        	where Volunteer_Job__c = :jobId limit 999]) {
		            SelectOption so = new SelectOption(jrs.id, jrs.Weekly_Occurrence__c + ' ' + jrs.Days_of_Week__c + ' ' + jrs.Schedule_Start_Date_Time__c.format() + '&nbsp;&nbsp;&nbsp;&nbsp;(' + jrs.name + ')' );
		            so.setEscapeItem(false); 
		            listSO.add(so);
		        }
		        listSOJRS = listSO;
    		}       
	        return listSOJRS;
    	}
    	set;
    }	
    
    // action method called by the page when the Job has changed.
    // this allows us to refresh the lsit of JRS's for the new job.
    public PageReference refreshListSOJRS() {
    	listSOJRS = null;
    	return null;
    }
    
    // action method called by the page when the user chooses a JRS to copy from.
    public PageReference copyScheduleFromJRS() {
		if (jrsId != null) {
			Job_Recurrence_Schedule__c jrs = [select Days_of_Week__c, Duration__c, 
		        	Schedule_Start_Date_Time__c, Schedule_End_Date__c, Weekly_Occurrence__c from Job_Recurrence_Schedule__c 
		        	where Id = :jrsId ];
		    
		    // copy appropriate values
		    vrs.Days_of_Week__c = jrs.Days_of_Week__c;
		    vrs.Duration__c = jrs.Duration__c;
		    vrs.Schedule_Start_Date_Time__c = datetime.newInstance(system.today(), jrs.Schedule_Start_Date_Time__c.time());
		    vrs.Schedule_End_Date__c = jrs.Schedule_End_Date__c;
		    vrs.Weekly_Occurrence__c = jrs.Weekly_Occurrence__c;
		}    	
		return null;
    }


    //******************************************************************************************************
    // Test Methods
    public static testmethod void TestNewAndEditVRS() {

		// create test data
        Campaign cmp = new Campaign(recordtypeid=VOL_SharedCode.recordtypeIdVolunteersCampaign, 
        	name='Job Test Campaign', IsActive=true);
        insert cmp;
        Volunteer_Job__c job = new Volunteer_Job__c(name='Job1', campaign__c=cmp.Id);
        insert job;
		Contact contact = new Contact(firstname='test', lastname='test');
		insert contact;
        Job_Recurrence_Schedule__c jrs = new Job_Recurrence_Schedule__c(Volunteer_Job__c = job.Id);
		jrs.Days_of_Week__c = 'Monday;Wednesday;Friday';
		jrs.Duration__c = 1;
		jrs.Schedule_Start_Date_Time__c = datetime.parse('1/1/2012 10:00 AM');
		jrs.Schedule_End_Date__c = date.parse('12/31/2012');
		jrs.Weekly_Occurrence__c = 'Every';
		jrs.Desired_Number_of_Volunteers__c = 5;
		insert jrs;
		
		// scenario 1: creating a new VRS
		Volunteer_Recurrence_Schedule__c vrs = new Volunteer_Recurrence_Schedule__c();
		ApexPages.StandardController stdCtrl = new ApexPages.StandardController(vrs);		
		VOL_CTRL_NewAndEditVRS ctrl = new VOL_CTRL_NewAndEditVRS(stdCtrl);
		ctrl.vrs.Contact__c = contact.Id; 
		ctrl.vrs.Volunteer_Job__c = job.Id;
		ctrl.vrs.Days_of_Week__c = 'Monday;Friday';
		ctrl.vrs.Duration__c = 1.5;
		ctrl.vrs.Schedule_Start_Date_Time__c = datetime.parse('2/1/2012 10:00 AM');
		ctrl.vrs.Schedule_End_Date__c = date.parse('6/30/2012');
		ctrl.vrs.Weekly_Occurrence__c = '1st';
		stdCtrl.Save();
		
		// verify it got saved
		list<Volunteer_Recurrence_Schedule__c> listVRS = [select Id from Volunteer_Recurrence_Schedule__c where Volunteer_Job__c = :job.Id];
		system.assertEquals(1, listVRS.size());
		
		// scenario 2: updating an existing VRS
		vrs = [select Id, Days_of_Week__c from Volunteer_Recurrence_Schedule__c where Id = :listVRS[0].Id];
		ApexPages.StandardController stdCtrl2 = new ApexPages.StandardController(vrs);		
		VOL_CTRL_NewAndEditVRS ctrl2 = new VOL_CTRL_NewAndEditVRS(stdCtrl2);
		system.assertEquals('Monday;Friday', ctrl2.vrs.Days_of_Week__c);
		ctrl2.vrs.Days_of_Week__c = 'Saturday';
		stdCtrl.Save();
		vrs = [select Id, Days_of_Week__c from Volunteer_Recurrence_Schedule__c where Id = :listVRS[0].Id];
		system.assertEquals('Saturday', ctrl2.vrs.Days_of_Week__c);
		
		// scneario 3: copying from an existing JRS
		ctrl.vrs.Volunteer_Job__c = job.Id;
		system.assert(ctrl.refreshListSOJRS() == null);
		system.assertEquals(2, ctrl.listSOJRS.size());
		ctrl.jrsId = jrs.Id;
		system.assert(ctrl.copyScheduleFromJRS() == null);
		system.assertEquals('Monday;Wednesday;Friday', ctrl.vrs.Days_of_Week__c);
						
    }
	

}