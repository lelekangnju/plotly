% Generated by roxygen2 (4.1.1): do not edit by hand
% Please edit documentation in R/tools.R
\name{get_credentials_file}
\alias{get_credentials_file}
\title{Read Plotly credentials file (which is a JSON)}
\usage{
get_credentials_file(args = c())
}
\arguments{
\item{args}{Character vector of keys you are looking up}
}
\value{
List of keyword-value pairs (credentials)
}
\description{
Read Plotly credentials file (which is a JSON)
}
\examples{
\dontrun{
get_credentials_file(c("username", "api_key"))
}
}

