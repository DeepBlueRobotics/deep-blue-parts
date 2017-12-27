$(document).ready(function() {
    $(":text:visible:enabled:first").focus();
});

function verifyPasswordMatch(form) {
  if (form.password.value == form.password2.value) {
    return true;
  } else {
    alert("The passwords do not match.");
    return false;
  }
}
function verifyFileTypes(form) {
  if(form.documentation.value!=""){
    if(form.documentation.value.match(/\.([^\.]+)$/)[1] != "pdf"){
      alert("Documentation file type is invalid")
      return false;
    }
  }
  else if(form.drawing.value!=""){
    if(form.documentation.value.match(/\.([^\.]+)$/)[1] != "pdf"){
        alert("Documentation file type is invalid")
        return false;
    }
  }
  else if(form.toolpath.value!=""){
      if(form.documentation.value.match(/\.([^\.]+)$/)[1] != "gcode"){
        alert("Documentation file type is invalid")
        return false;
      }
  }
  else {
    return true;
  }
}
// Global variables to store current filter state for auto-refresh.
var dashboardProjectId, dashboardStatus;

function changeDashboardFilter(projectId, status) {
  dashboardProjectId = projectId;
  dashboardStatus = status;
  loadParts();
}

function loadParts() {
  $.ajax({
    url: "/projects/" + dashboardProjectId + "/dashboard/parts?status=" + dashboardStatus,
    complete: function(response) {
      $("#dashboard-parts").html(response.responseText);
      $("#dashboard-parts").tooltip({
        selector: ".dashboard-part",
        placement: "bottom"
      });
    }
  });
}

function vendorAutoComplete(selector) {
  $(selector).typeahead({
    source: vendors
  });
}

// Only allow editing one item at a time.
var editingOrderItem = false;

function editOrderItem(projectId, orderItemId) {
  if (editingOrderItem) {
    alert("Can only edit one item at a time.");
    return;
  }
  editingOrderItem = true;
  $.ajax({
    url: "/projects/" + projectId + "/order_items/" + orderItemId + "/editable",
    complete: function(response) {
      $("#order-item-" + orderItemId).html(response.responseText);
      vendorAutoComplete("#edit-vendor");
      $("#edit-vendor").focus();
    }
  });
}

$(function() {
  vendorAutoComplete("#vendor");
  $(".datepicker").datepicker();
});
