// Written by David Habib, copyright (c) 2012 Groundwire, 1402 3rd Avenue, Suite 1000, Seattle, WA 98101
// This program is released under the GNU Affero General Public License, Version 3. http://www.gnu.org/licenses/

trigger VOL_JRS_MaintainShifts on Job_Recurrence_Schedule__c (after insert, after undelete, after update, before delete) {
	
    if (trigger.isInsert || trigger.isUpdate || trigger.isUnDelete) {
        VOL_JRS.ProcessListJRS(trigger.new, true);  
    }
    
    if (trigger.isDelete) {
        VOL_JRS.DeleteListJRS(trigger.old);        
    }
}