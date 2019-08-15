function render_commit_cell(cell, position) {

	var cell_val = cell.getValue();
	var authorship_metadata = cell.getRow().getData()[position]["record"]["payload"]["metadata"];

	if (cell_val && authorship_metadata) {
		var msg_subject = get_commit_subject(authorship_metadata["payload"]);

		var author_firstname = authorship_metadata["author"].split(" ")[0];

		return sha1_link(cell_val) + " <b>" + author_firstname + ":</b> " + msg_subject;
	} else {
		return "";
	}
}


function downstream_impact_by_week(html_element_id, api_url) {

//	var weeks_count = $('#weeks-count-input').val();
	const weeks_count = 8; // TODO Create UI element

	$.getJSON(api_url, {"weeks": weeks_count}, function (data) {

		var pointlist = [];
		for (var datum of data) {
			pointlist.push([Date.parse(datum["week"]), datum["impact"]["downstream_broken_commit_count"]]);
		}

		var series_list = [{
				name: "Commits broken by upstream",
				data: pointlist,
			}];


		Highcharts.chart(html_element_id, {
			chart: {
				type: 'line'
			},
			title: {
				text: 'Downstream collateral by Week'
			},
			subtitle: {
				text: 'Showing only full weeks, starting on labeled day'
			},
			xAxis: {
				type: 'datetime',
				dateTimeLabelFormats: { // don't display the dummy year
					month: '%e. %b',
					year: '%b'
				},
				title: {
					text: 'Date'
				}
			},
			yAxis: [
				{
					title: {
						text: 'Broken downstream commits',
					},
				},
			],
			tooltip: {
				useHTML: true,
				style: {
					pointerEvents: 'auto'
				},
			},
			plotOptions: {
				line: {
					marker: {
						enabled: true
					}
				},
			},
			credits: {
				enabled: false
			},
			series: series_list,
		});
	});
}



function gen_annotated_breakage_author_stats_table(element_id, data_url) {

	var table = new Tabulator("#" + element_id, {
		height:"300px",
		layout:"fitColumns",
		placeholder:"No Data Set",
		columns:[
			{title: "Author", field: "breakage_commit_author",
			},
			{title: "Breakage count", field: "distinct_breakage_count",
			},
			{title: "Breakage time", field: "cumulative_breakage_duration_seconds",
				formatter: function(cell, formatterParams, onRendered) {
					return moment.duration(cell.getValue(), 'seconds').humanize();
				},
			},
			{title: "Downstream commits affected", field: "cumulative_downstream_affected_commits",
			},
			{title: "Master commits spanned", field: "cumulative_spanned_master_commits",
			},
		],
		ajaxURL: data_url,
	});
}


function gen_detected_breakages_table(element_id, data_url) {

	var table = new Tabulator("#" + element_id, {
		height:"300px",
		layout:"fitColumns",
		placeholder:"No Data Set",
		columns:[
			{title: "Job count", field: "job_count",
				width: 75,
			},
			{title: "Length", field: "modal_run_length",
			},
			{title: "Jobs", field: "jobs_delimited",
			},
			{title: "First commit", field: "first_commit",
				formatter: function(cell, formatterParams, onRendered) {
					return sha1_link(cell.getValue());
				},
			},
			{title: "Last commit", field: "modal_last_commit",
				formatter: function(cell, formatterParams, onRendered) {
					return sha1_link(cell.getValue());
				},
			},
		],
		ajaxURL: data_url,
	});
}


function gen_nonannotated_detected_breakages_table(element_id, data_url) {

	var table = new Tabulator("#" + element_id, {
		height:"300px",
		layout:"fitColumns",
		placeholder:"No Data Set",
		columns:[
			{title: "Job count", field: "job_count",
				width: 75,
			},
		],
		ajaxURL: data_url,
	});
}


function getModesSelectorValues(failure_modes_dict) {

	var modes_by_revertibility = {};
	for (var mode_id in failure_modes_dict) {
		var props = failure_modes_dict[mode_id];

		// Note: using a boolean as a dictionary key turns it into a string
		var revertible_list = setDefault(modes_by_revertibility, props["revertible"], []);
		revertible_list.push({label: props["label"], value: mode_id});
	}

	var modes_selector_values = [];
	for (var revertibility in modes_by_revertibility) {
		var vals = modes_by_revertibility[revertibility];

		var outer_label = (revertibility === 'true') ? "revertible" : "nonrevertible";
		modes_selector_values.push({label: outer_label, options: vals});
	}

	return modes_selector_values;
}


function gen_annotated_breakages_table(element_id, data_url, failure_modes_dict) {

	var modes_selector_values = getModesSelectorValues(failure_modes_dict);

	var table = new Tabulator("#" + element_id, {
		height:"300px",
		layout:"fitColumns",
		placeholder:"No Data Set",
		columns:[
			{title: "Action", columns: [
				{title:"X",
					headerSort: false,
					formatter: function(cell, formatterParams, onRendered){
					    return "<img src='/images/trash-icon.png' style='width: 16;'/>";
					},
					width:40,
					align:"center",
					cellClick:function(e, cell) {

						var cause_id = cell.getRow().getData()["start"]["db_id"];

						if (confirm("Realy delete cause #" + cause_id + "?")) {
							post_modification("/api/code-breakage-delete", {"cause_id": cause_id});
						}
					},
				},
				{title:"?",
					headerSort: false,
					formatter: function(cell, formatterParams, onRendered) {
						var cause_id = cell.getRow().getData()["start"]["db_id"];
						return link("<img src='/images/view-icon.png' style='width: 16;'/>", "/breakage-details.html?cause=" + cause_id);
					},
					width:40,
					align:"center",
				},
				{title:"#",
					headerSort: false,
					formatter: function(cell, formatterParams, onRendered) {

						const row_data = cell.getRow().getData();

						const start_commit_index = row_data["start"]["record"]["payload"]["breakage_commit"]["db_id"];

						var link_url = "/master-timeline.html";
						if (row_data["end"] != null) {
							const end_commit_index = row_data["end"]["record"]["payload"]["resolution_commit"]["db_id"];
							link_url = "/master-timeline.html?min_commit_index=" + start_commit_index + "&max_commit_index=" + end_commit_index;
						}

						return link("<img src='/images/view-icon.png' style='width: 16;'/>", link_url);
					},
					width:40,
					align:"center",
				},
			]},
			{title: "Mode", width: 150, field: "start.record.payload.breakage_mode.payload",
				formatter: function(cell, formatterParams, onRendered) {
					var value = cell.getValue();
					return failure_modes_dict[value]["label"] || "?";
				},
				editor:"select",
				editorParams: {
					values: modes_selector_values,
				},
				cellEdited: function(cell) {
					var cause_id = cell.getRow().getData()["start"]["db_id"];
					var new_failure_mode = cell.getValue();
					console.log("updating failure mode to: " + new_failure_mode);

					var data_dict = {"cause_id": cause_id, "mode": new_failure_mode};
					post_modification("/api/code-breakage-mode-update", data_dict);
				},
			},
			{title: "Notes", width: 150, field: "start.record.payload.description",
				editor: "input",
				cellEdited: function(cell) {
					var cause_id = cell.getRow().getData()["start"]["db_id"];
					var new_description = cell.getValue();

					var data_dict = {"cause_id": cause_id, "description": new_description};
					post_modification("/api/code-breakage-description-update", data_dict);
				},
			},
			{title: "Downstream Impact", columns: [
				{title: "Commits",
					field: "impact_stats.downstream_broken_commit_count",
					width: 75,
				},
				{title: "Builds",
					field: "impact_stats.failed_downstream_build_count",
					width: 75,
				},
			]},
			{title: "Span", columns: [
				{title: "Commit count", width: 100, field: "spanned_commit_count",
					headerSort: true,
				},
				{title: "Duration", width: 100, field: "commit_timespan_seconds",
					headerSort: true,
					formatter: function(cell, formatterParams, onRendered) {
						return moment.duration(cell.getValue(), 'seconds').humanize();
					},
				},
			]},
			{title: "Start", columns: [
				{title: "commit", width: 300, field: "start.record.payload.breakage_commit.record",
					formatter: function(cell, formatterParams, onRendered) {
						return render_commit_cell(cell, "start");
					},
				},
				{title: "when", width: 100, field: "start.record.payload.metadata.created",
					formatter: function(cell, formatterParams, onRendered) {
						var committed_time = cell.getValue();
//						var committed_time = cell.getRow().getData()["start"]["record"]["payload"]["metadata"]["created"];
						const time_moment = moment(committed_time);
						return time_moment.format("h:mm a") + " (" + time_moment.fromNow() + ")";
					},
				},
				{title: "annotated", width: 250, field: "start.record.created",
					formatter: function(cell, formatterParams, onRendered) {
						var val = cell.getValue();
						var start_obj = cell.getRow().getData()["start"];
						return moment(val).fromNow() + " by " + start_obj["record"]["author"];
					},
				},
			]},
			{title: "End", columns: [
				{title: "commit", width: 300, field: "end.record.payload.resolution_commit.record",
					formatter: function(cell, formatterParams, onRendered) {
						return render_commit_cell(cell, "end");
					},
				},
				{title: "reported", width: 250,
					formatter: function(cell, formatterParams, onRendered) {
						var val = cell.getValue();

						var end_obj = cell.getRow().getData()["end"];

						if (end_obj && end_obj["record"]) {

							var end_record = end_obj["record"];
							return moment(end_record["created"]).fromNow() + " by " + end_record["author"];
						}

						return "";
					},
				},
			]},
			{title: "Affected jobs", columns: [
				{title: "Count",
					width: 75,
					formatter: function(cell, formatterParams, onRendered) {
						var joblist = cell.getRow().getData()["start"]["record"]["payload"]["affected_jobs"];
						return joblist.length;
					},
				},
				{title: "Names", field: "start.record.payload.affected_jobs",
					tooltip: function(cell) {

						var cell_value = cell.getValue();
						return cell_value.join("\n");
					},
					formatter: function(cell, formatterParams, onRendered) {
						var cell_val = cell.getValue();
						var items = [];
						for (var jobname of cell_val) {
							items.push(jobname);
						}

						return items.join(", ");
					},
				},
			]},
		],
		ajaxURL: data_url,
	});
}


function gen_failure_modes_chart(container_id) {

	$.getJSON('/api/master-deterministic-failure-modes', function (data) {

		Highcharts.chart(container_id, {
			chart: {
				plotBackgroundColor: null,
				plotBorderWidth: null,
				plotShadow: false,
				type: 'pie'
			},
			title: {
				text: 'Failure modes'
			},
			tooltip: {
				pointFormat: '{series.name}: <b>{point.percentage:.1f}%</b>'
			},
			plotOptions: {
				pie: {
					allowPointSelect: true,
					cursor: 'pointer',
					dataLabels: {
						enabled: true,
						format: '<b>{point.name}</b>: {point.percentage:.1f} %',
						style: {
							color: (Highcharts.theme && Highcharts.theme.contrastTextColor) || 'black'
						}
					}
				}
			},
			credits: {
				enabled: false
			},
			series: [{
				name: 'Failure modes',
				colorByPoint: true,
				data: data.rows,
			}],
		});
	});
}


function main() {

	// TODO Apply throbber to more fetches
	$("#scan-throbber").show();
	$.getJSON('/api/list-failure-modes', function (mydata) {

		$("#scan-throbber").hide();

		var failure_modes_dict = {};
		for (var item of mydata) {
			failure_modes_dict[item["db_id"]] = item["record"];
		}

		gen_annotated_breakages_table("annotated-breakages-table", "/api/code-breakages-annotated", failure_modes_dict);
	});

	gen_failure_modes_chart("container-failure-modes");

	gen_annotated_breakage_author_stats_table("annotated-breakage-author-stats-table", "/api/code-breakages-author-stats");

	gen_nonannotated_detected_breakages_table("detected-leftovers-table", "/api/code-breakages-leftover-detected");
	gen_detected_breakages_table("detected-breakages-table", "/api/code-breakages-detected");

	downstream_impact_by_week("container-downstream-impact-by-week", "/api/downstream-impact-weekly");

	// TODO
//	gen_nonannotated_commit_detected_breakages_table("detected-commit-leftovers-table", "/api/code-breakages-leftover-by-commit");
}

